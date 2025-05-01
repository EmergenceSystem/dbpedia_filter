-module(dbpedia_filter_app).
-behaviour(application).
-behaviour(cowboy_handler).

%% Application callbacks
-export([start/2, stop/1]).

%% Cowboy handler callbacks
-export([init/2, terminate/3]).

-define(DBPEDIA_ENDPOINT, "https://dbpedia.org/sparql").

%% Application behavior
start(_StartType, _StartArgs) ->
    {ok, Port} = em_filter:find_port(),
    em_filter_sup:start_link(dbpedia_filter, ?MODULE, Port).

stop(_State) ->
    ok.

%% Cowboy handler behavior
init(Req0, State) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    io:format("Received body: ~p~n", [Body]),
    EmbryoList = generate_embryo_list(Body),
    Response = #{embryo_list => EmbryoList},
    EncodedResponse = jsone:encode(Response),
    Req2 = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        EncodedResponse,
        Req
    ),
    {ok, Req2, State}.

terminate(_Reason, _Req, _State) ->
    ok.

generate_embryo_list(JsonBinary) ->
    case jsone:decode(JsonBinary, [{keys, atom}]) of
        Search when is_map(Search) ->
            Value = binary_to_list(maps:get(value, Search, <<"">>)),
            Timeout = list_to_integer(binary_to_list(maps:get(timeout, Search, <<"10">>))),
            % Ensuring dbo is a binary before conversion to list
            Dbo = case maps:get(dbo, Search, <<"Company">>) of
                Bin when is_binary(Bin) -> binary_to_list(Bin);
                Str when is_list(Str) -> Str;
                _ -> "Company"
            end,
            
            Query = lists:flatten(io_lib:format(
                "PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#> "
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
                "}} ", [Value, Dbo])),
            
            EncodedQuery = uri_string:quote(Query),
            Params = "query=" ++ EncodedQuery,
            Url = ?DBPEDIA_ENDPOINT,
            
            Headers = [{"Accept", "application/sparql-results+json"}],
            ContentType = "application/x-www-form-urlencoded",
            HttpOptions = [{timeout, Timeout * 1000}],
            Options = [{body_format, binary}],
            
            io:format("Sending query to DBpedia: ~p~n", [Query]),
            StartTime = erlang:system_time(millisecond),
            
            case httpc:request(post, {Url, Headers, ContentType, Params}, HttpOptions, Options) of
                {ok, {{_, 200, _}, _, Body}} ->
                    io:format("Received response from DBpedia. Body length: ~p~n", [byte_size(Body)]),
                    parse_dbpedia_response(Body, StartTime, Timeout * 1000);
                {error, Reason} ->
                    io:format("Error fetching query results: ~p~n", [Reason]),
                    []
            end;
        {error, Reason} ->
            io:format("Error decoding JSON: ~p~n", [Reason]),
            []
    end.

parse_dbpedia_response(ResponseBody, StartTime, Timeout) ->
    try jsone:decode(ResponseBody) of
        Json ->
            case get_path(Json, [<<"results">>, <<"bindings">>]) of
                Bindings when is_list(Bindings) ->
                    io:format("Found ~p result items~n", [length(Bindings)]),
                    process_bindings(Bindings, StartTime, Timeout, []);
                _ ->
                    io:format("No results found in response~n"),
                    []
            end
    catch
        error:Reason ->
            io:format("Failed to parse JSON response: ~p~n", [Reason]),
            []

    end.

process_bindings([], _StartTime, _Timeout, Acc) ->
    lists:reverse(Acc);
process_bindings([Binding | Rest], StartTime, Timeout, Acc) ->
    CurrentTime = erlang:system_time(millisecond),
    case CurrentTime - StartTime >= Timeout of
        true ->
            io:format("Timeout reached after processing ~p results~n", [length(Acc)]),
            lists:reverse(Acc);
        false ->
            case process_binding(Binding) of
                {ok, Embryo} ->
                    process_bindings(Rest, StartTime, Timeout, [Embryo | Acc]);
                skip ->
                    process_bindings(Rest, StartTime, Timeout, Acc)
            end
    end.

process_binding(Binding) ->
    case {get_path(Binding, [<<"url">>, <<"value">>]), 
          get_path(Binding, [<<"abstract">>, <<"value">>])} of
        {Url, Abstract} when is_binary(Url), is_binary(Abstract) ->
            io:format("Extracted URL: ~p~n", [Url]),
            Embryo = #{
                properties => #{
                    <<"url">> => Url,
                    <<"resume">> => Abstract
                }
            },
            {ok, Embryo};
        _ ->
            io:format("Missing data in binding, skipping~n"),
            skip
    end.

%% Helper function to safely get nested values from a JSON structure
get_path(Json, []) ->
    Json;
get_path(Json, [Key | Rest]) when is_map(Json) ->
    case maps:find(Key, Json) of
        {ok, Value} -> get_path(Value, Rest);
        error -> undefined
    end;
get_path(_, _) ->
    undefined.
