-module(plugin_handler).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").

-export([install/0, handle/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-export([add_plugin/3, remove_plugin/2]).

-define(KNOWN_PLUGINS, [scheduler_plugin]).

-record(state, {authorized_users,
                known_plugins=?KNOWN_PLUGINS}).

%% API functions

install() ->
    UserEnv = os:getenv("TATARU_AUTHORIZED", ""),
    AuthUsers = lists:map(fun binary:list_to_bin/1,
                          lists:filter(fun(X) -> X =/= "" end,
                                       string:split(UserEnv, ";"))),
    {ok, Pid} = gen_server:start_link(?MODULE, [AuthUsers], []),
    Pid.

handle(Pid, Msg) ->
    gen_server:cast(Pid, {msg, Msg}).

%% gen_server callbacks

init([AuthUsers]) ->
    {ok, #state{authorized_users=AuthUsers}}.

handle_call(_Msg, _From, State) ->
    {noreply, State}.

handle_cast({msg, Msg}, State=#state{authorized_users=AuthUsers}) ->
    #{<<"content">> := Content} = Msg,
    Parts = binary:split(Content, <<" ">>, [global, trim_all]),
    case Parts of
        [_, <<"plugin">>, <<"add">>, Rest] ->
            authorized_command(add_plugin, AuthUsers, Msg, [Rest, Msg, State]);
        [_, <<"plugin">>, <<"remove">>, Rest] ->
            authorized_command(remove_plugin, AuthUsers, Msg, [Rest, Msg]);
        [_, <<"plugin">>, <<"list">>] ->
            list_plugins(Msg);
        _ ->
            ?LOG_INFO("unmatched command: ~p", [Parts])
    end,
    {noreply, State}.

%% helper functions

authorized_command(Fn, AuthUsers, Msg, Args) ->
    #{<<"author">> := #{<<"id">> := AuthorId}} = Msg,
    case lists:member(AuthorId, AuthUsers) of
        true -> apply(?MODULE, Fn, Args);
        false ->
            send_reply(<<"you are not authorized for that command">>, Msg)
    end.

send_reply(Reply, Message) ->
    #{<<"channel_id">> := ChannelId,
      <<"author">> := #{<<"id">> := AuthorId}} = Message,
    ApiServer = discord_sup:get_api_server(),
    R = <<"<@!", AuthorId/binary, "> ", Reply/binary>>,
    discord_api:send_message(ApiServer, ChannelId, R).

atom_plugin(Plugin) ->
    try
        {ok, binary_to_existing_atom(Plugin)}
    catch
        error:badarg -> {error, unknown_argument}
    end.

add_plugin(Plugin, Msg, State) ->
    case atom_plugin(Plugin) of
        {ok, PluginAtom} -> handle_add(PluginAtom, Plugin, Msg, State);
        {error, unknown_argument} ->
            send_reply(<<"unknown plugin: ", Plugin/binary>>, Msg)
    end.

handle_add(Plugin, PluginBin, Msg, State) ->
    case lists:member(Plugin, State#state.known_plugins) of
        false ->
            send_reply(<<"unknown plugin: ", PluginBin/binary>>, Msg);
        true ->
            PluginServer = tataru_sup:get_plugin_server(),
            case plugin_server:add_plugin(PluginServer, Plugin) of
                ok ->
                    send_reply(<<"plugin ", PluginBin/binary,  " added">>, Msg);
                {error, already_installed} ->
                    Reply = <<"plugin ", PluginBin/binary,
                              " already installed">>,
                    send_reply(Reply, Msg)
            end
    end.

remove_plugin(<<"plugin_handler">>, Msg) ->
    send_reply(<<"I'm afraid I can't do that, Dave">>, Msg);
remove_plugin(Plugin, Msg) ->
    case atom_plugin(Plugin) of
        {ok, PluginAtom} -> handle_remove(PluginAtom, Plugin, Msg);
        {error, unknown_argument} ->
            send_reply(<<"unknown plugin: ", Plugin/binary>>, Msg)
    end.

handle_remove(Plugin, PluginBin, Msg) ->
    PluginServer = tataru_sup:get_plugin_server(),
    case plugin_server:remove_plugin(PluginServer, Plugin) of
        ok ->
            send_reply(<<"plugin ", PluginBin/binary,  " removed">>, Msg);
        {error, not_installed} ->
            Reply = <<"plugin ", PluginBin/binary,
                      " not installed">>,
            send_reply(Reply, Msg)
    end.

binjoin(A, B) -> <<A/binary, B/binary>>.

list_plugins(Msg) ->
    PluginServer = tataru_sup:get_plugin_server(),
    {ok, Plugins} = plugin_server:list_plugins(PluginServer),
    BinPlugins = lists:map(fun atom_to_binary/1, Plugins),
    PluginBin = lists:foldl(fun binjoin/2, <<>>,
                            lists:join(<<", ">>, BinPlugins)),
    send_reply(<<"Installed: ", PluginBin/binary>>, Msg).
