% This file is licensed to you under the Apache License,
% Version 2.0 (the "License"); you may not use this file
% except in compliance with the License.  You may obtain
% a copy of the License at
%
% http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing,
% software distributed under the License is distributed on an
% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
% KIND, either express or implied.  See the License for the
% specific language governing permissions and limitations
% under the License.
%%% @author Fernando Benavides <elbrujohalcon@inaka.net>
%%% @doc A pool of workers. If you want to put it in your supervisor tree,
%%%      remember it's a supervisor.
-module(wpool_pool).

-behaviour(supervisor).

%% API
-export([start_link/2]).
-export([best_worker/1, random_worker/1, next_worker/1, hash_worker/2,
         next_available_worker/1, send_request_available_worker/3, call_available_worker/3]).
-export([cast_to_available_worker/2, broadcast/2]).
-export([stats/0, stats/1, get_workers/1]).
-export([worker_name/2, find_wpool/1]).
-export([next/2, wpool_get/2]).
-export([add_callback_module/2, remove_callback_module/2]).
%% Supervisor callbacks
-export([init/1]).

-record(wpool,
        {name :: wpool:name(),
         size :: pos_integer(),
         next :: atomics:atomics_ref(),
         workers :: tuple(),
         opts :: [wpool:option()],
         qmanager :: wpool_queue_manager:queue_mgr(),
         born = erlang:system_time(second) :: integer()}).

-opaque wpool() :: #wpool{}.

-export_type([wpool/0]).

%% ===================================================================
%% API functions
%% ===================================================================

%% @doc Starts a supervisor with several {@link wpool_process}es as its children
-spec start_link(wpool:name(), [wpool:option()]) ->
                    {ok, pid()} | {error, {already_started, pid()} | term()}.
start_link(Name, Options) ->
    supervisor:start_link({local, Name}, ?MODULE, {Name, Options}).

%% @doc Picks the worker with the smaller queue of messages.
%% @throws no_workers
-spec best_worker(wpool:name()) -> atom().
best_worker(Name) ->
    case find_wpool(Name) of
        undefined ->
            exit(no_workers);
        Wpool ->
            min_message_queue(Wpool)
    end.

%% @doc Picks a random worker
%% @throws no_workers
-spec random_worker(wpool:name()) -> atom().
random_worker(Name) ->
    case find_wpool(Name) of
        undefined ->
            exit(no_workers);
        Wpool = #wpool{size = Size} ->
            WorkerNumber = fast_rand_uniform(Size),
            nth_worker_name(Wpool, WorkerNumber)
    end.

%% @doc Picks the next worker in a round robin fashion
%% @throws no_workers
-spec next_worker(wpool:name()) -> atom().
next_worker(Name) ->
    case find_wpool(Name) of
        undefined ->
            exit(no_workers);
        Wpool = #wpool{next = Atomic, size = Size} ->
            Index = atomics:get(Atomic, 1),
            NextIndex = next_to_check(Index, Size),
            _ = atomics:compare_exchange(Atomic, 1, Index, NextIndex),
            nth_worker_name(Wpool, Index)
    end.

%% @doc Picks the first available worker, if any
%% @throws no_workers | no_available_workers
-spec next_available_worker(wpool:name()) -> atom().
next_available_worker(Name) ->
    case find_wpool(Name) of
        undefined ->
            exit(no_workers);
        Wpool ->
            case worker_with_no_task(Wpool) of
                undefined ->
                    exit(no_available_workers);
                Worker ->
                    Worker
            end
    end.

%% @doc Picks the first available worker and sends the call to it.
%%      The timeout provided includes the time it takes to get a worker
%%      and for it to process the call.
%% @throws no_workers | timeout
-spec call_available_worker(wpool:name(), any(), timeout()) -> atom().
call_available_worker(Name, Call, Timeout) ->
    case wpool_queue_manager:call_available_worker(queue_manager_name(Name), Call, Timeout) of
        noproc ->
            exit(no_workers);
        timeout ->
            exit(timeout);
        Result ->
            Result
    end.

%% @doc Picks the first available worker and sends the request to it.
%%      The timeout provided considers only the time it takes to get a worker
-spec send_request_available_worker(wpool:name(), any(), timeout()) ->
                                       noproc | timeout | reference().
send_request_available_worker(Name, Call, Timeout) ->
    wpool_queue_manager:send_request_available_worker(queue_manager_name(Name),
                                                      Call,
                                                      Timeout).

%% @doc Picks a worker base on a hash result.
%%      <pre>phash2(Term, Range)</pre> returns hash = integer,
%%      0 &lt;= hash &lt; Range so <pre>1</pre> must be added
%% @throws no_workers
-spec hash_worker(wpool:name(), term()) -> atom().
hash_worker(Name, HashKey) ->
    case find_wpool(Name) of
        undefined ->
            exit(no_workers);
        Wpool = #wpool{size = WpoolSize} ->
            Index = 1 + erlang:phash2(HashKey, WpoolSize),
            nth_worker_name(Wpool, Index)
    end.

%% @doc Casts a message to the first available worker.
%%      Since we can wait forever for a wpool:cast to be delivered
%%      but we don't want the caller to be blocked, this function
%%      just forwards the cast when it gets the worker
-spec cast_to_available_worker(wpool:name(), term()) -> ok.
cast_to_available_worker(Name, Cast) ->
    wpool_queue_manager:cast_to_available_worker(queue_manager_name(Name), Cast).

%% @doc Casts a message to all the workers within the given pool.
-spec broadcast(wpool:name(), term()) -> ok.
broadcast(Name, Cast) ->
    lists:foreach(fun(Worker) -> ok = wpool_process:cast(Worker, Cast) end,
                  all_workers(Name)).

-spec all() -> [wpool:name()].
all() ->
    [Name || {{?MODULE, Name}, _} <- persistent_term:get(), find_wpool(Name) /= undefined].

%% @doc Retrieves the list of worker registered names.
%% This can be useful to manually inspect the workers or do custom work on them.
-spec get_workers(wpool:name()) -> [atom()].
get_workers(Name) ->
    all_workers(Name).

%% @doc Retrieves the pool stats for all pools
-spec stats() -> [wpool:stats()].
stats() ->
    [stats(Name) || Name <- all()].

%% @doc Retrieves a snapshot of the pool stats
%% @throws no_workers
-spec stats(wpool:name()) -> wpool:stats().
stats(Name) ->
    case find_wpool(Name) of
        undefined ->
            exit(no_workers);
        Wpool ->
            stats(Wpool, Name)
    end.

stats(Wpool, Name) ->
    {Total, WorkerStats} =
        lists:foldl(fun(N, {T, L}) ->
                       case worker_info(Wpool,
                                        N,
                                        [message_queue_len,
                                         memory,
                                         current_function,
                                         current_location,
                                         dictionary])
                       of
                           undefined ->
                               {T, L};
                           [{message_queue_len, MQL} = MQLT,
                            Memory,
                            Function,
                            Location,
                            {dictionary, Dictionary}] ->
                               WS = [MQLT, Memory]
                                    ++ function_location(Function, Location)
                                    ++ task(proplists:get_value(wpool_task, Dictionary)),
                               {T + MQL, [{N, WS} | L]}
                       end
                    end,
                    {0, []},
                    lists:seq(1, Wpool#wpool.size)),
    PendingTasks = wpool_queue_manager:pending_task_count(Wpool#wpool.qmanager),
    [{pool, Name},
     {supervisor, erlang:whereis(Name)},
     {options, lists:ukeysort(1, proplists:unfold(Wpool#wpool.opts))},
     {size, Wpool#wpool.size},
     {next_worker, atomics:get(Wpool#wpool.next, 1)},
     {total_message_queue_len, Total + PendingTasks},
     {workers, WorkerStats}].

worker_info(Wpool, N, Info) ->
    case erlang:whereis(nth_worker_name(Wpool, N)) of
        undefined ->
            undefined;
        Worker ->
            erlang:process_info(Worker, Info)
    end.

function_location({current_function, {gen_server, loop, _}}, _) ->
    [];
function_location({current_function, {erlang, hibernate, _}}, _) ->
    [];
function_location(Function, Location) ->
    [Function, Location].

task(undefined) ->
    [];
task({_TaskId, Started, Task}) ->
    Time =
        calendar:datetime_to_gregorian_seconds(
            calendar:universal_time()),
    [{task, Task}, {runtime, Time - Started}].

%% @doc Set next within the worker pool record. Useful when using
%% a custom strategy function.
-spec next(pos_integer(), wpool()) -> wpool().
next(Next, WPool = #wpool{next = Atomic}) ->
    atomics:put(Atomic, 1, Next),
    WPool.

%% @doc Adds a callback module.
%%      The module must implement the <pre>wpool_process_callbacks</pre> behaviour.
-spec add_callback_module(wpool:name(), module()) -> ok | {error, term()}.
add_callback_module(Pool, Module) ->
    EventManager = event_manager_name(Pool),
    wpool_process_callbacks:add_callback_module(EventManager, Module).

%% @doc Removes a callback module.
-spec remove_callback_module(wpool:name(), module()) -> ok | {error, term()}.
remove_callback_module(Pool, Module) ->
    EventManager = event_manager_name(Pool),
    wpool_process_callbacks:remove_callback_module(EventManager, Module).

%% @doc Get values from the worker pool record. Useful when using a custom
%% strategy function.
-spec wpool_get(atom(), wpool()) -> any();
               ([atom()], wpool()) -> any().
wpool_get(List, WPool) when is_list(List) ->
    [g(Atom, WPool) || Atom <- List];
wpool_get(Atom, WPool) when is_atom(Atom) ->
    g(Atom, WPool).

g(name, #wpool{name = Ret}) ->
    Ret;
g(size, #wpool{size = Ret}) ->
    Ret;
g(next, #wpool{next = Ret}) ->
    atomics:get(Ret, 1);
g(opts, #wpool{opts = Ret}) ->
    Ret;
g(qmanager, #wpool{qmanager = Ret}) ->
    Ret;
g(born, #wpool{born = Ret}) ->
    Ret.

-spec time_checker_name(wpool:name()) -> atom().
time_checker_name(Name) ->
    list_to_atom(?MODULE_STRING ++ [$- | atom_to_list(Name)] ++ "-time-checker").

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================
%% @private
-spec init({wpool:name(), [wpool:option()]}) ->
              {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init({Name, Options}) ->
    Size = proplists:get_value(workers, Options, 100),
    QueueType = proplists:get_value(queue_type, Options),
    OverrunHandler =
        proplists:get_value(overrun_handler, Options, {error_logger, warning_report}),
    TimeChecker = time_checker_name(Name),
    QueueManager = queue_manager_name(Name),
    ProcessSup = process_sup_name(Name),
    EventManagerName = event_manager_name(Name),
    _Wpool = store_wpool(Name, Size, Options),
    TimeCheckerSpec =
        {TimeChecker,
         {wpool_time_checker, start_link, [Name, TimeChecker, OverrunHandler]},
         permanent,
         brutal_kill,
         worker,
         [wpool_time_checker]},
    QueueManagerSpec =
        {QueueManager,
         {wpool_queue_manager, start_link, [Name, QueueManager, [{queue_type, QueueType}]]},
         permanent,
         brutal_kill,
         worker,
         [wpool_queue_manager]},

    EventManagerSpec =
        {EventManagerName,
         {gen_event, start_link, [{local, EventManagerName}]},
         permanent,
         brutal_kill,
         worker,
         dynamic},

    SupShutdown = proplists:get_value(pool_sup_shutdown, Options, brutal_kill),
    WorkerOpts =
        [{queue_manager, QueueManager}, {time_checker, TimeChecker} | Options]
        ++ maybe_event_manager(Options, {event_manager, EventManagerName}),
    ProcessSupSpec =
        {ProcessSup,
         {wpool_process_sup, start_link, [Name, ProcessSup, WorkerOpts]},
         permanent,
         SupShutdown,
         supervisor,
         [wpool_process_sup]},

    Children =
        [TimeCheckerSpec, QueueManagerSpec]
        ++ maybe_event_manager(Options, EventManagerSpec)
        ++ [ProcessSupSpec],

    SupIntensity = proplists:get_value(pool_sup_intensity, Options, 5),
    SupPeriod = proplists:get_value(pool_sup_period, Options, 60),
    SupStrategy = {one_for_all, SupIntensity, SupPeriod},
    {ok, {SupStrategy, Children}}.

%% @private
-spec nth_worker_name(wpool(), pos_integer()) -> atom().
nth_worker_name(#wpool{workers = Workers}, I) ->
    element(I, Workers).

-spec worker_name(wpool:name(), pos_integer()) -> atom().
worker_name(Name, I) ->
    list_to_atom(?MODULE_STRING ++ [$- | atom_to_list(Name)] ++ [$- | integer_to_list(I)]).

%% ===================================================================
%% Private functions
%% ===================================================================
process_sup_name(Name) ->
    list_to_atom(?MODULE_STRING ++ [$- | atom_to_list(Name)] ++ "-process-sup").

queue_manager_name(Name) ->
    list_to_atom(?MODULE_STRING ++ [$- | atom_to_list(Name)] ++ "-queue-manager").

event_manager_name(Name) ->
    list_to_atom(?MODULE_STRING ++ [$- | atom_to_list(Name)] ++ "-event-manager").

worker_with_no_task(#wpool{size = Size} = Wpool) ->
    %% Moving the beginning of the list to a random point to ensure that clients
    %% do not always start asking for process_info to the processes that are most
    %% likely to have bigger message queues
    First = fast_rand_uniform(Size),
    worker_with_no_task(0, Size, First, Wpool).

worker_with_no_task(Size, Size, _, _) ->
    undefined;
worker_with_no_task(Step, Size, ToCheck, Wpool) ->
    Worker = nth_worker_name(Wpool, ToCheck),
    case try_process_info(whereis(Worker), [message_queue_len, dictionary]) of
        [{message_queue_len, 0}, {dictionary, Dictionary}] ->
            case proplists:get_value(wpool_task, Dictionary) of
                undefined ->
                    Worker;
                _ ->
                    worker_with_no_task(Step + 1, Size, next_to_check(ToCheck, Size), Wpool)
            end;
        _ ->
            worker_with_no_task(Step + 1, Size, next_to_check(ToCheck, Size), Wpool)
    end.

try_process_info(undefined, _) ->
    [];
try_process_info(Pid, Keys) ->
    erlang:process_info(Pid, Keys).

min_message_queue(#wpool{size = Size} = Wpool) ->
    %% Moving the beginning of the list to a random point to ensure that clients
    %% do not always start asking for process_info to the processes that are most
    %% likely to have bigger message queues
    First = fast_rand_uniform(Size),
    Worker = nth_worker_name(Wpool, First),
    QLength = queue_length(whereis(Worker)),
    min_message_queue(0, Size, First, Wpool, QLength, Worker).

min_message_queue(_, _, _, _, 0, Worker) ->
    Worker;
min_message_queue(Size, Size, _, _, _QLength, Worker) ->
    Worker;
min_message_queue(Step, Size, ToCheck, Wpool, CurrentQLength, CurrentWorker) ->
    Worker = nth_worker_name(Wpool, ToCheck),
    QLength = queue_length(whereis(Worker)),
    Next = next_to_check(ToCheck, Size),
    case QLength < CurrentQLength of
        true ->
            min_message_queue(Step + 1, Size, Next, Wpool, QLength, Worker);
        false ->
            min_message_queue(Step + 1, Size, Next, Wpool, CurrentQLength, CurrentWorker)
    end.

next_to_check(Next, Size) ->
    Next rem Size + 1.

fast_rand_uniform(Range) ->
    UI = erlang:unique_integer(),
    1 + erlang:phash2(UI, Range).

queue_length(undefined) ->
    infinity;
queue_length(Pid) when is_pid(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, L} ->
            L;
        undefined ->
            infinity
    end.

-spec all_workers(wpool:name()) -> [atom()].
all_workers(Name) ->
    case find_wpool(Name) of
        undefined ->
            exit(no_workers);
        #wpool{workers = Workers} ->
            tuple_to_list(Workers)
    end.

%% ===================================================================
%% Storage functions
%% ===================================================================
store_wpool(Name, Size, Options) ->
    Atomic = atomics:new(1, [{signed, false}]),
    atomics:put(Atomic, 1, 1),
    WorkerNames = list_to_tuple([worker_name(Name, I) || I <- lists:seq(1, Size)]),
    WPool =
        #wpool{name = Name,
               size = Size,
               next = Atomic,
               workers = WorkerNames,
               opts = Options,
               qmanager = queue_manager_name(Name)},
    persistent_term:put({?MODULE, Name}, WPool),
    WPool.

%% @doc Use this function to get the Worker pool record in a custom worker.
-spec find_wpool(atom()) -> undefined | wpool().
find_wpool(Name) ->
    try {erlang:whereis(Name), persistent_term:get({?MODULE, Name})} of
        {undefined, _} ->
            undefined;
        {_, WPool} ->
            WPool
    catch
        _:badarg ->
            build_wpool(Name)
    end.

%% @doc We use this function not to report an error if for some reason we've
%% lost the record on the persistent_term table. This SHOULDN'T be called too much.
build_wpool(Name) ->
    error_logger:warning_msg("Building a #wpool record for ~p. Something must have failed.",
                             [Name]),
    try supervisor:count_children(process_sup_name(Name)) of
        Children ->
            Size = proplists:get_value(active, Children, 0),
            store_wpool(Name, Size, [])
    catch
        _:Error ->
            error_logger:warning_msg("Wpool ~p not found: ~p", [Name, Error]),
            undefined
    end.

maybe_event_manager(Options, Item) ->
    EnableEventManager = proplists:get_value(enable_callbacks, Options, false),
    case EnableEventManager of
        true ->
            [Item];
        _ ->
            []
    end.
