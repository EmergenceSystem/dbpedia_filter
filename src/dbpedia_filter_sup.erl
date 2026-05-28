%%%-------------------------------------------------------------------
%%% @doc dbpedia_filter supervisor.
%%%
%%% Supervises the dbpedia_filter_server gen_server.
%%% @end
%%%-------------------------------------------------------------------
-module(dbpedia_filter_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    ServerSpec = #{
        id      => dbpedia_filter_server,
        start   => {dbpedia_filter_server, start_link, []},
        restart => permanent,
        type    => worker
    },
    {ok, {#{strategy => one_for_one, intensity => 3, period => 10},
          [ServerSpec]}}.
