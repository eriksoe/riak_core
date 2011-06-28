%% -------------------------------------------------------------------
%%
%% riak_core_coverage_plan: TODO
%%
%% Copyright (c) 2007-2011 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc TODO

-module(riak_core_coverage_plan).
-author('Kelly McLaughlin <kelly@basho.com>').

%% API
-export([
         create_plan/4
         ]).
         
-define(RINGTOP, trunc(math:pow(2,160)-1)).  % SHA-1 space

%% ===================================================================
%% Public API
%% ===================================================================

%% @doc TODO
create_plan(Bucket, _PVC, ReqId, Service) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    case Bucket of
        all ->
            %% It sucks, but for operations involving all buckets
            %% we have to check all vnodes because of variable n_val.
            NVal = 1;
        _ ->
            BucketProps = riak_core_bucket:get_bucket(Bucket, Ring),
            NVal = proplists:get_value(n_val, BucketProps)
    end,
    PartitionCount = riak_core_ring:num_partitions(Ring),
    %% Get the list of all nodes and the list of available
    %% nodes so we can have a list of unavailable nodes
    %% while creating a coverage plan.
    Nodes = riak_core_ring:all_members(Ring),
    %% Check which nodes are up for the specified service
    %% so we can determine which VNodes are ineligible 
    %% to be part of the coverage plan.
    UpNodes = riak_core_node_watcher:nodes(Service),
    %% Create a coverage plan with the requested coverage factor
    %% Get a list of the VNodes owned by any unavailble nodes
    DownVNodes = [Index || {Index, Node} <- riak_core_ring:all_owners(Ring), lists:member(Node, (Nodes -- UpNodes))],
    %% Calculate an offset based on the request id to offer
    %% the possibility of different sets of VNodes being
    %% used even when all nodes are available.
    Offset = ReqId rem NVal,

    RingIndexInc = ?RINGTOP div PartitionCount,
    AllKeySpaces = lists:seq(0, PartitionCount - 1),
    UnavailableKeySpaces = [(DownVNode div RingIndexInc) || DownVNode <- DownVNodes],
    %% The offset value serves as a tiebreaker in the
    %% compare_next_vnode function and is used to distribute
    %% work to different sets of VNodes.
    AvailableKeySpaces = [{((VNode+Offset) rem PartitionCount), VNode, n_keyspaces(VNode, NVal, PartitionCount)}
                          || VNode <- (AllKeySpaces -- UnavailableKeySpaces)],
    CoverageResult = find_coverage(ordsets:from_list(AllKeySpaces), AvailableKeySpaces, []),
    case CoverageResult of
        {ok, CoveragePlan} ->
            %% Assemble the data structures required for
            %% executing the coverage operation.
            CoverageVNodeFun = fun({Position, KeySpaces}, Acc) ->
                                       %% Calculate the VNode index using the
                                       %% ring position and the increment of
                                       %% ring index values.
                                       VNodeIndex = (Position rem PartitionCount) * RingIndexInc,
                                       Node = riak_core_ring:index_owner(Ring, VNodeIndex),
                                       CoverageVNode = {VNodeIndex, Node},
                                       case length(KeySpaces) < NVal of
                                           true ->
                                               %% Get the VNode index of each keyspace to
                                               %% use to filter results from this VNode.
                                               KeySpaceIndexes = [(((KeySpaceIndex+1) rem PartitionCount) * RingIndexInc)
                                                                  || KeySpaceIndex <- KeySpaces],
                                               Acc1 = orddict:append(Node, {VNodeIndex, KeySpaceIndexes}, Acc),
                                               {CoverageVNode, Acc1};
                                           false ->
                                               {CoverageVNode, Acc}
                                       end
                               end,
            {CoverageVNodes, FilterVNodes} = lists:mapfoldl(CoverageVNodeFun, [], CoveragePlan),
            NodeIndexes = group_indexes_by_node(CoverageVNodes, []),
            {NodeIndexes, CoverageVNodes, FilterVNodes};
       {insufficient_vnodes_available, _KeySpace, _Coverage}  ->
            {error, insufficient_vnodes_available}
    end.

%% ====================================================================
%% Internal functions
%% ====================================================================

%% @private
%% @doc Find the N key spaces for a VNode
n_keyspaces(VNode, N, PartitionCount) ->
     ordsets:from_list([X rem PartitionCount || X <- lists:seq(PartitionCount + VNode - N, PartitionCount + VNode - 1)]).

%% @private
%% @doc Find a minimal set of covering VNodes
find_coverage([], _, Coverage) ->
    {ok, lists:sort(Coverage)};
find_coverage(KeySpace, [], Coverage) ->
    {insufficient_vnodes_available, KeySpace, lists:sort(Coverage)};
find_coverage(KeySpace, Available, Coverage) ->
    Res = next_vnode(KeySpace, Available),
        case Res of
        {0, _, _} -> % out of vnodes
            find_coverage(KeySpace, [], Coverage);
        {_NumCovered, VNode, _} ->
            {value, {_, VNode, Covers}, UpdAvailable} = lists:keytake(VNode, 2, Available),
            UpdCoverage = [{VNode, ordsets:intersection(KeySpace, Covers)} | Coverage],
            UpdKeySpace = ordsets:subtract(KeySpace, Covers),
            find_coverage(UpdKeySpace, UpdAvailable, UpdCoverage)
    end.

%% @private
%% @doc Find the next vnode that covers the most of the
%% remaining keyspace. Use VNode id as tie breaker.
next_vnode(KeySpace, Available) ->
    CoverCount = [{covers(KeySpace, CoversKeys), VNode, TieBreaker} || {TieBreaker, VNode, CoversKeys} <- Available],
    hd(lists:sort(fun compare_next_vnode/2, CoverCount)).

%% @private
%% There is a potential optimization here once
%% the partition claim logic has been changed
%% so that physical nodes claim partitions at
%% regular intervals around the ring.
%% The optimization is for the case
%% when the partition count is not evenly divisible
%% by the n_val and when the coverage counts of the
%% two arguments are equal and a tiebreaker is
%% required to determine the sort order. In this
%% case, choosing the lower node for the final
%% vnode to complete coverage will result
%% in an extra physical node being involved
%% in the coverage plan so the optimization is
%% to choose the upper node to minimize the number
%% of physical nodes.
compare_next_vnode({CA, _VA, TBA}, {CB, _VB, TBB}) ->
    if
        CA > CB -> %% Descending sort on coverage
            true;
        CA < CB ->
            false;
        true ->
            TBA < TBB %% If equal coverage choose the lower node.
    end.

%% @private
%% @doc Count how many of CoversKeys appear in KeySpace
covers(KeySpace, CoversKeys) ->
    ordsets:size(ordsets:intersection(KeySpace, CoversKeys)).

%% @private
group_indexes_by_node([], NodeIndexes) ->
    NodeIndexes;
group_indexes_by_node([{Index, Node} | OtherVNodes], NodeIndexes) ->
    NodeIndexes1 = orddict:append(Node, Index, NodeIndexes),
    group_indexes_by_node(OtherVNodes, NodeIndexes1).

