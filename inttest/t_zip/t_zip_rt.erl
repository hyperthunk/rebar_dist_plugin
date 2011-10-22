-module(t_zip_rt).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

files() ->
    [{copy, 
        "../../rebar", "rebar"},
     {copy,
        "../../examples/project-zip/ebin", "ebin"},
     {copy,
        "../../examples/project-zip/include", "include"},
     {copy,
        "../../examples/project-zip/priv", "priv"},
     {copy,
        "../../examples/project-zip/src", "src"},
     {copy, "rebar.config", "rebar.config"}].

run(_Dir) ->
    Verbose = case rebar_config:is_verbose() of
        true -> 
            "-v";
        _ ->
            ""
    end,
    ?assertMatch({ok, _}, retest:sh("./rebar get-deps " ++ Verbose, [])),
    % ?assertMatch({ok, _}, retest:sh("./rebar compile-deps " ++ Verbose, [])),
    ?assertMatch({ok, _}, retest:sh("./rebar cl comp", [])),
    ?assertMatch({ok, _}, retest:sh("./rebar dist " ++ Verbose, [])),
    ?assertMatch({ok, _}, retest:sh("unzip myproject-1.zip", [{dir, "dist"}])),
    ?assert(exists("myproject/ebin/myproject.app")),
    ?assert(exists("myproject/ebin/myproject_app.beam")),
    ?assert(exists("myproject/ebin/myproject_sup.beam")),
    ?assert(exists("myproject/include/myproject.hrl")),
    ?assert(exists("myproject/priv/script.sh")),
    ?assert(not exists("myproject/src")),
    ok.

exists(F) ->
    filelib:is_regular(expected_file(F)).

expected_file(Path) ->
    filename:join("dist", Path).