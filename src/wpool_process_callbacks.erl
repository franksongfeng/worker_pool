-module(wpool_process_callbacks).

-behaviour(gen_event).

%% The callbacks are called in an extremely dynamic from call/3.
-hank([unused_callbacks]).

-export([init/1, handle_event/2, handle_call/2]).
-export([notify/3, add_callback_module/2, remove_callback_module/2]).

-type state() :: module().
-type event() :: handle_init_start | handle_worker_creation | handle_worker_death.

-callback handle_init_start(wpool:name()) -> any().
-callback handle_worker_creation(wpool:name()) -> any().
-callback handle_worker_death(wpool:name(), term()) -> any().

-optional_callbacks([handle_init_start/1, handle_worker_creation/1,
                     handle_worker_death/2]).

%% @private
-spec init(module()) -> {ok, state()}.
init(Module) ->
    {ok, Module}.

%% @private
-spec handle_event({event(), [any()]}, state()) -> {ok, state()}.
handle_event({Event, Args}, Module) ->
    call(Module, Event, Args),
    {ok, Module}.

%% @private
-spec handle_call(Msg, state()) -> {ok, {error, {unexpected_call, Msg}}, state()}.
handle_call(Msg, State) ->
    {ok, {error, {unexpected_call, Msg}}, State}.

%% @doc Sends a notification to all registered callback modules.
-spec notify(event(), #{event_manager := any(), _ => _}, [any()]) -> ok.
notify(Event, #{event_manager := EventMgr}, Args) ->
    gen_event:notify(EventMgr, {Event, Args});
notify(_, _, _) ->
    ok.

%% @doc Adds a callback module.
-spec add_callback_module(wpool:name(), module()) -> ok | {error, any()}.
add_callback_module(EventManager, Module) ->
    case ensure_loaded(Module) of
        ok ->
            gen_event:add_handler(EventManager, {wpool_process_callbacks, Module}, Module);
        Other ->
            Other
    end.

%% @doc Removes a callback module.
-spec remove_callback_module(wpool:name(), module()) -> ok | {error, any()}.
remove_callback_module(EventManager, Module) ->
    gen_event:delete_handler(EventManager, {wpool_process_callbacks, Module}, Module).

call(Module, Event, Args) ->
    try
        case erlang:function_exported(Module, Event, length(Args)) of
            true ->
                erlang:apply(Module, Event, Args);
            _ ->
                ok
        end
    catch
        E:R ->
            error_logger:warning_msg("Could not call callback module, error:~p, reason:~p", [E, R])
    end.

ensure_loaded(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            ok;
        {error, embedded} -> %% We are in embedded mode so the module was loaded if exists
            ok;
        Other ->
            Other
    end.
