-module(t_extconf_rt).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

files() ->
    [{copy,
        "../../examples/external-config", "external-config"},
     {copy, "rebar.config", "external-config/rebar.config"}].

run(_Dir) ->
    Verbose = case rebar_config:is_verbose() of
        true -> 
            "-v";
        _ ->
            ""
    end,
    ?assertMatch({ok, _}, retest:sh("rebar get-deps compile-deps " ++ Verbose,
                                    [{dir, "external-config"}])),
    ?assertMatch({ok, _}, retest:sh("rebar cl comp dist " ++ Verbose,
                                    [{dir, "external-config"}])),
    ?assertMatch({ok, _}, retest:sh("tar -zxf foo-1.2.3.tar.gz",
                                    [{dir, "external-config/dist"}])),

    ?assert(not exists("foo/priv/build/bar.sh")),
    ?assert(not exists("foo/priv/build/foo.sh")),
    ?assert(exists("foo/ebin/foo.beam")),
    ?assert(exists("foo/ebin/foo.app")),
    
    Script = expected_file("foo/priv/ascript.sh"),
    ?assert(filelib:is_regular(Script)),
    ?assert(file_contains_data(Script, "this is a template variable => BAZ")),

    ?assertMatch({ok, _}, retest:sh("rebar distclean " ++ Verbose,
                                    [{dir, "external-config"}])),
    ?assert(filelib:is_dir("external-config/dist") == false),
    ok.

exists(F) ->
    filelib:is_regular(expected_file(F)).

expected_file(Path) ->
    filename:join("external-config/dist", Path).

file_contains_data(File, Data) ->
    {ok, Content} = file:read_file(File),
    case re:run(binary_to_list(Content), Data) of
        {match,_} ->
            true;
        _ -> 
            false
    end.
