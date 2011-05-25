-module(t_simpleconf_rt).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

files() ->
    [{copy,
        "../../examples/custom-assembly", "custom-assembly"},
     {copy, "rebar.config", "custom-assembly/rebar.config"}].

run(Dir) ->
    ?assertMatch({ok, _}, retest:sh("rebar get-deps compile-deps -v",
                                    [{dir, "custom-assembly"}])),
    ?assertMatch({ok, _}, retest:sh("rebar escriptize dist -v",
                                    [{dir, "custom-assembly"}])),
    ?assertMatch({ok, _}, retest:sh("tar -zxf custom_app.tar.gz",
                                    [{dir, "custom-assembly/target"}])),
    File = filename:join(Dir, "custom-assembly/target/custom_app/priv/bin/custom-app"),
    retest_log:log(debug, "Checking File: ~p~n", [File]),
    ?assert(filelib:is_regular(File)),
    ?assertMatch({ok, _}, retest:sh("rebar distclean -v",
                                    [{dir, "custom-assembly"}])),
    ?assert(filelib:is_dir("custom-assembly/target") == false),
    ok.
