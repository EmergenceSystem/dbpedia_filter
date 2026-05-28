%%%-------------------------------------------------------------------
%%% @doc DBpedia SPARQL agent.
%%%
%%% Uses the DBpedia Lookup API to find matching entities, then
%%% enriches each hit with its English abstract via a targeted
%%% SPARQL query on the known URI.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(dbpedia_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(LOOKUP_ENDPOINT, "https://lookup.dbpedia.org/api/search").
-define(SPARQL_ENDPOINT, "https://dbpedia.org/sparql").
-define(MAX_RESULTS, 10).

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"dbpedia">>, <<"sparql">>,
                                      <<"semantic">>, <<"encyclopedia">>,
                                      <<"wikipedia">>].

%%====================================================================
%% Application lifecycle
%%====================================================================

start(_Type, _Args) ->
    case dbpedia_filter_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(dbpedia_filter_query_listener),
    catch em_pop_sup:stop_node(dbpedia_filter),
    ok.

%%====================================================================
%% Internal
%%====================================================================

start_pop_and_http() ->
    PopPort   = application:get_env(dbpedia_filter, pop_port,   9420),
    QueryPort = application:get_env(dbpedia_filter, query_port, 9421),
    Seeds     = application:get_env(dbpedia_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(dbpedia_filter),
    catch cowboy:stop_listener(dbpedia_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(dbpedia_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(
        fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end,
        Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => dbpedia_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(dbpedia_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[dbpedia_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Pipeline: Lookup -> abstract enrichment
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout, TypeClass} = extract_params(JsonBinary),
    case Value of
        [] -> [];
        _  ->
            Hits = lookup(Value, TypeClass, Timeout),
            enrich_with_abstracts(Hits, Timeout)
    end.

lookup(Value, TypeClass, Timeout) ->
    TypeParam = case TypeClass of
        ""  -> "";
        _   -> "&QueryClass=" ++ uri_string:quote(TypeClass)
    end,
    Url = ?LOOKUP_ENDPOINT
          ++ "?QueryString=" ++ uri_string:quote(Value)
          ++ "&MaxHits=" ++ integer_to_list(?MAX_RESULTS)
          ++ TypeParam,
    case httpc:request(get, {Url, []}, [{timeout, Timeout * 1000}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_lookup_xml(Body);
        {ok, {{_, Status, _}, _, _}} ->
            io:format("[dbpedia] lookup HTTP ~p~n", [Status]),
            [];
        {error, Reason} ->
            io:format("[dbpedia] lookup failed: ~p~n", [Reason]),
            []
    end.

parse_lookup_xml(Body) ->
    Uris  = re_all(Body, <<"<URI>([^<]+)</URI>">>),
    Descs = re_all(Body, <<"<Description>([^<]*)</Description>">>),
    Padded = Descs ++ lists:duplicate(max(0, length(Uris) - length(Descs)), undefined),
    [#{uri => U, comment => D} || {U, D} <- lists:zip(Uris, Padded)].

re_all(Body, Re) ->
    case re:run(Body, Re, [global, {capture, all_but_first, binary}]) of
        {match, Matches} -> [M || [M] <- Matches];
        _                -> []
    end.

enrich_with_abstracts([], _Timeout) -> [];
enrich_with_abstracts(Hits, Timeout) ->
    Uris = [Uri || #{uri := Uri} <- Hits, Uri =/= undefined],
    AbstractMap = fetch_abstracts(Uris, Timeout),
    lists:filtermap(fun(#{uri := Uri, comment := Comment}) ->
        Abstract = maps:get(Uri, AbstractMap, Comment),
        WikiUrl  = uri_to_wiki(Uri),
        case {WikiUrl, Abstract} of
            {W, A} when is_binary(W), is_binary(A) ->
                {true, #{<<"properties">> => #{<<"url">> => W, <<"resume">> => A}}};
            _ ->
                false
        end
    end, Hits).

uri_to_wiki(Uri) when is_binary(Uri) ->
    case binary:split(Uri, <<"/resource/">>) of
        [_, Name] -> <<"https://en.wikipedia.org/wiki/", Name/binary>>;
        _         -> undefined
    end;
uri_to_wiki(_) -> undefined.

fetch_abstracts([], _Timeout) -> #{};
fetch_abstracts(Uris, Timeout) ->
    Values = string:join(
        [lists:flatten(io_lib:format("(<~s>)", [binary_to_list(U)])) || U <- Uris],
        " "),
    Query = lists:flatten(io_lib:format(
        "PREFIX dbo: <http://dbpedia.org/ontology/> "
        "SELECT ?s ?abstract WHERE { "
        "  VALUES (?s) { ~s } "
        "  ?s dbo:abstract ?abstract . "
        "  FILTER (langMatches(lang(?abstract), \"en\")) "
        "} LIMIT ~p",
        [Values, length(Uris)])),
    Params  = "query=" ++ uri_string:quote(Query),
    Headers = [{"Accept", "application/sparql-results+json"}],
    case httpc:request(post,
                       {?SPARQL_ENDPOINT, Headers,
                        "application/x-www-form-urlencoded", Params},
                       [{timeout, Timeout * 1000}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_abstract_response(Body);
        {error, Reason} ->
            io:format("[dbpedia] sparql failed: ~p~n", [Reason]),
            #{}
    end.

parse_abstract_response(Body) ->
    try json:decode(Body) of
        Json ->
            case get_path(Json, [<<"results">>, <<"bindings">>]) of
                Bindings when is_list(Bindings) ->
                    lists:foldl(fun(B, Acc) ->
                        S = get_path(B, [<<"s">>,        <<"value">>]),
                        A = get_path(B, [<<"abstract">>, <<"value">>]),
                        case {S, A} of
                            {Su, Ab} when is_binary(Su), is_binary(Ab) -> Acc#{Su => Ab};
                            _ -> Acc
                        end
                    end, #{}, Bindings);
                _ -> #{}
            end
    catch
        _:_ -> #{}
    end.

%%====================================================================
%% Helpers
%%====================================================================

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value     = binary_to_list(maps:get(<<"value">>, Map,
                            maps:get(<<"query">>, Map, <<"">>))),
            Timeout   = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            TypeClass = binary_to_list(maps:get(<<"dbo">>, Map, <<"">>)),
            {Value, Timeout, TypeClass};
        _ ->
            {binary_to_list(JsonBinary), 10, ""}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10, ""}
    end.

get_path(Json, []) -> Json;
get_path(Json, [Key | Rest]) when is_map(Json) ->
    case maps:find(Key, Json) of
        {ok, Value} -> get_path(Value, Rest);
        error       -> undefined
    end;
get_path(_, _) -> undefined.
