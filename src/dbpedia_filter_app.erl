%%%-------------------------------------------------------------------
%%% @doc DBpedia SPARQL agent.
%%%
%%% Queries the DBpedia SPARQL endpoint for entities matching the
%%% search value and returns their Wikipedia URL and abstract.
%%%
%%% As an agent this module:
%%%   - Announces capabilities to em_disco on startup via `agent_hello'.
%%%   - Maintains a memory of URLs already returned, so duplicate
%%%     results across successive queries are filtered out.
%%%
%%% Handler contract: `handle/2' (Body, Memory) -> {RawList, NewMemory}.
%%% Returns a raw Erlang list — em_filter_server encodes it.
%%% Memory schema: `#{seen => #{binary_url => true}}'.
%%% @end
%%%-------------------------------------------------------------------
-module(dbpedia_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/1, handle/2]).

-define(DBPEDIA_ENDPOINT, "https://dbpedia.org/sparql").

-define(CAPABILITIES, [
    <<"dbpedia">>,
    <<"sparql">>,
    <<"semantic">>,
    <<"encyclopedia">>,
    <<"wikipedia">>
]).

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_agent(dbpedia_filter, ?MODULE, #{
        capabilities => ?CAPABILITIES,
        memory       => ets
    }).

stop(_State) ->
    em_filter:stop_filter(dbpedia_filter).

%%====================================================================
%% Agent handler — with memory (primary path)
%%
%% Memory holds the set of URLs already returned to the client.
%% New results are filtered against this set before being returned,
%% then the set is updated with the fresh URLs.
%%
%% Returns a raw list of embryo maps — NOT pre-encoded JSON.
%% em_filter_server wraps and encodes the result.
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    Seen    = maps:get(seen, Memory, #{}),
    Embryos = generate_embryo_list(Body),

    %% Filter out URLs the agent has already returned in a previous query.
    Fresh = [E || E <- Embryos,
                  not maps:is_key(url_of(E), Seen)],

    %% Accumulate newly seen URLs into memory.
    NewSeen = lists:foldl(fun(E, Acc) ->
        Acc#{url_of(E) => true}
    end, Seen, Fresh),

    {Fresh, Memory#{seen => NewSeen}};

handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Plain filter handler — kept for backward compatibility.
%% Called when the agent is started without memory (handle/1 path).
%% Returns a raw list — em_filter_server encodes it.
%%====================================================================

handle(Body) when is_binary(Body) ->
    generate_embryo_list(Body);
handle(_) ->
    [].

%%====================================================================
%% Search and processing (unchanged)
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout, Dbo} = extract_params(JsonBinary),
    Query = build_sparql_query(Value, Dbo),
    Params = "query=" ++ uri_string:quote(Query),
    Headers = [{"Accept", "application/sparql-results+json"}],
    StartTime = erlang:system_time(millisecond),
    case httpc:request(post,
                       {?DBPEDIA_ENDPOINT, Headers,
                        "application/x-www-form-urlencoded", Params},
                       [{timeout, Timeout * 1000}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_dbpedia_response(Body, StartTime, Timeout * 1000);
        _ ->
            []
    end.

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value   = binary_to_list(maps:get(<<"value">>,   Map, <<"">>)),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            Dbo = binary_to_list(maps:get(<<"dbo">>, Map, <<"Company">>)),
            {Value, Timeout, Dbo};
        _ ->
            {binary_to_list(JsonBinary), 10, "Company"}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10, "Company"}
    end.

build_sparql_query(Value, Dbo) ->
    lists:flatten(io_lib:format(
        "PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#> "
        "PREFIX foaf: <http://xmlns.com/foaf/0.1/> "
        "SELECT DISTINCT ?url ?abstract "
        "WHERE {{ "
        "  {{ "
        "    ?s a ?type ; "
        "      rdfs:label ?label ; "
        "      <http://dbpedia.org/ontology/abstract> ?abstract ; "
        "      foaf:isPrimaryTopicOf ?url . "
        "      FILTER (langMatches(lang(?abstract), \"en\")) "
        "      FILTER (contains(?label, \"~s\")) "
        "      FILTER (?type IN (<http://dbpedia.org/ontology/~s>)) "
        "  }} "
        "}} ", [Value, Dbo])).

%%--------------------------------------------------------------------
%% Response parsing (unchanged)
%%--------------------------------------------------------------------

parse_dbpedia_response(Body, StartTime, Timeout) ->
    try json:decode(Body) of
        Json ->
            case get_path(Json, [<<"results">>, <<"bindings">>]) of
                Bindings when is_list(Bindings) ->
                    process_bindings(Bindings, StartTime, Timeout, []);
                _ ->
                    []
            end
    catch
        _:_ -> []
    end.

process_bindings([], _StartTime, _Timeout, Acc) ->
    lists:reverse(Acc);
process_bindings([Binding | Rest], StartTime, Timeout, Acc) ->
    case erlang:system_time(millisecond) - StartTime >= Timeout of
        true  -> lists:reverse(Acc);
        false ->
            NewAcc = case process_binding(Binding) of
                {ok, Embryo} -> [Embryo | Acc];
                skip         -> Acc
            end,
            process_bindings(Rest, StartTime, Timeout, NewAcc)
    end.

process_binding(Binding) ->
    Url      = get_path(Binding, [<<"url">>,      <<"value">>]),
    Abstract = get_path(Binding, [<<"abstract">>, <<"value">>]),
    case {Url, Abstract} of
        {U, A} when is_binary(U), is_binary(A) ->
            {ok, #{
                <<"properties">> => #{
                    <<"url">>    => U,
                    <<"resume">> => A
                }
            }};
        _ -> skip
    end.

%% Safely traverses a nested map structure.
get_path(Json, []) -> Json;
get_path(Json, [Key | Rest]) when is_map(Json) ->
    case maps:find(Key, Json) of
        {ok, Value} -> get_path(Value, Rest);
        error       -> undefined
    end;
get_path(_, _) -> undefined.

%%====================================================================
%% Internal helpers
%%====================================================================

%% Extracts the URL from an embryo map for memory tracking.
-spec url_of(map()) -> binary().
url_of(#{<<"properties">> := #{<<"url">> := Url}}) -> Url;
url_of(_) -> <<>>.
