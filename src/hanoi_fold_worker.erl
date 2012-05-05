%% ----------------------------------------------------------------------------
%%
%% hanoi: LSM-trees (Log-Structured Merge Trees) Indexed Storage
%%
%% Copyright 2011-2012 (c) Trifork A/S.  All Rights Reserved.
%% http://trifork.com/ info@trifork.com
%%
%% Copyright 2012 (c) Basho Technologies, Inc.  All Rights Reserved.
%% http://basho.com/ info@basho.com
%%
%% This file is provided to you under the Apache License, Version 2.0 (the
%% "License"); you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
%% License for the specific language governing permissions and limitations
%% under the License.
%%
%% ----------------------------------------------------------------------------

-module(hanoi_fold_worker).
-author('Kresten Krab Thorup <krab@trifork.com>').

-define(log(Fmt,Args),ok).

%%
%% This worker is used to merge fold results from individual
%% levels. First, it receives a message
%%
%%  {initialize, [LevelWorker, ...]}
%%
%%  And then from each LevelWorker, a sequence of
%%
%%   {level_result, LevelWorker, Key1, Value}
%%   {level_result, LevelWorker, Key2, Value}
%%   {level_result, LevelWorker, Key3, Value}
%%   {level_result, LevelWorker, Key4, Value}
%%   ...
%%   {level_done, LevelWorker}
%%
%% The order of level workers in the initialize messge is top-down,
%% which is used to select between same-key messages from different
%% levels.
%%
%% This fold_worker process will then send to a designated SendTo target
%% a similar sequence of messages
%%
%%   {fold_result, self(), Key1, Value}
%%   {fold_result, self(), Key2, Value}
%%   {fold_result, self(), Key3, Value}
%%   ...
%%   {fold_done, self()}.
%%

-export([start/1]).
-behavior(plain_fsm).
-export([data_vsn/0, code_change/3]).

-include("hanoi.hrl").

-record(state, {sendto}).

start(SendTo) ->
    PID = plain_fsm:spawn(?MODULE,
                          fun() ->
                                  process_flag(trap_exit,true),
                                  link(SendTo),
try
                                  initialize(#state{sendto=SendTo}, [])
catch
    Class:Ex ->
        error_logger:error_msg("Unexpected: ~p:~p ~p~n", [Class, Ex, erlang:get_stacktrace()]),
        exit({bad, Class, Ex, erlang:get_stacktrace()})
end
                          end),
    {ok, PID}.


initialize(State, PrefixFolders) ->

    Parent = plain_fsm:info(parent),
    receive
        die ->
            ok;

        {prefix, [_]=Folders} ->
            initialize(State, Folders);

        {initialize, Folders} ->

            Queues  = [ {PID,queue:new()} || PID <- (PrefixFolders ++ Folders) ],
            Initial = [ {PID,undefined} || PID <- (PrefixFolders ++ Folders) ],
            fill(State, Initial, Queues, PrefixFolders ++ Folders);

        %% gen_fsm handling
        {system, From, Req} ->
            plain_fsm:handle_system_msg(
              From, Req, State, fun(S1) -> initialize(S1, PrefixFolders) end);

        {'EXIT', Parent, Reason} ->
            plain_fsm:parent_EXIT(Reason, State)

    end.


fill(State, Values, Queues, []) ->
    emit_next(State, Values, Queues);

fill(State, Values, Queues, [PID|Rest]=PIDs) ->

%    io:format(user, "v=~P, q=~P, pids=~p~n", [Values, 10, Queues, 10, PIDs]),

    case lists:keyfind(PID, 1, Queues) of
        {PID, Q} ->
            case queue:out(Q) of
                {empty, Q} ->
                    fill_from_inbox(State, Values, Queues, PIDs, PIDs);

                {{value, Msg}, Q2} ->
                    Queues2 = lists:keyreplace(PID, 1, Queues, {PID, Q2}),

                    case Msg of
                        done ->
                            fill(State, lists:keydelete(PID, 1, Values), Queues2, Rest);
                        {_Key, _Value}=KV ->
                            fill(State, lists:keyreplace(PID, 1, Values, {PID, KV}), Queues2, Rest)
                    end
            end
    end.

fill_from_inbox(State, Values, Queues, [], PIDs) ->
    fill(State, Values, Queues, PIDs);

fill_from_inbox(State, Values, Queues, PIDs, SavePIDs) ->

    receive
        die ->
            ok;

        {level_done, PID} ->
            Queues2 = enter(PID, done, Queues),
            if PID == hd(PIDs) ->
                    fill_from_inbox(State, Values, Queues2, tl(PIDs), SavePIDs);
               true ->
                    fill_from_inbox(State, Values, Queues2, PIDs, SavePIDs)
            end;

        {level_limit, PID, Key} ->
            Queues2 = enter(PID, {Key, limit}, Queues),
            if PID == hd(PIDs) ->
                    fill_from_inbox(State, Values, Queues2, tl(PIDs), SavePIDs);
               true ->
                    fill_from_inbox(State, Values, Queues2, PIDs, SavePIDs)
            end;

        {level_result, PID, Key, Value} ->
            Queues2 = enter(PID, {Key, Value}, Queues),
            if PID == hd(PIDs) ->
                    fill_from_inbox(State, Values, Queues2, tl(PIDs), SavePIDs);
               true ->
                    fill_from_inbox(State, Values, Queues2, PIDs, SavePIDs)
            end;

        %% gen_fsm handling
        {system, From, Req} ->
            plain_fsm:handle_system_msg(
              From, Req, State, fun(S1) -> fill_from_inbox(S1, Values, Queues, PIDs, SavePIDs) end);

        {'EXIT', Parent, Reason}=Msg ->
            case plain_fsm:info(parent) == Parent of
                true ->
                    plain_fsm:parent_EXIT(Reason, State);
                false ->
                    error_logger:info_msg("unhandled EXIT message ~p~n", [Msg]),
                    fill_from_inbox(State, Values, Queues, PIDs, SavePIDs)
            end

    end.

enter(PID, Msg, Queues) ->
    {PID, Q} = lists:keyfind(PID, 1, Queues),
    Q2 = queue:in(Msg, Q),
    lists:keyreplace(PID, 1, Queues, {PID, Q2}).

emit_next(State, [], _Queues) ->
    ?log( "emit_next ~p~n", [[]]),
    Msg =  {fold_done, self()},
    Target = State#state.sendto,
    ?log( "~p ! ~p~n", [Target, Msg]),
    Target ! Msg,
    end_of_fold(State);

emit_next(State, [{FirstPID,FirstKV}|Rest]=Values, Queues) ->
    ?log( "emit_next ~p~n", [Values]),
    case
        lists:foldl(fun({P,{K1,_}=KV}, {{K2,_},_}) when K1 < K2 ->
                            {KV,[P]};
                       ({P,{K,_}}, {{K,_}=KV,List}) ->
                            {KV, [P|List]};
                       (_, Found) ->
                            Found
                    end,
                    {FirstKV,[FirstPID]},
                    Rest)
    of
        {{_, ?TOMBSTONE}, FillFrom} ->
            fill(State, Values, Queues, FillFrom);
        {{Key, limit}, _} ->
            ?log( "~p ! ~p~n", [State#state.sendto, {fold_limit, self(), Key}]),
            State#state.sendto ! {fold_limit, self(), Key},
            end_of_fold(State);
        {{Key, Value}, FillFrom} ->
            ?log( "~p ! ~p~n", [State#state.sendto, {fold_result, self(), Key, '...'}]),
            State#state.sendto ! {fold_result, self(), Key, Value},
            fill(State, Values, Queues, FillFrom)
    end.

end_of_fold(State) ->
    unlink(State#state.sendto),
    ok.

data_vsn() ->
    5.

code_change(_OldVsn, _State, _Extra) ->
    {ok, {#state{}, data_vsn()}}.

 
