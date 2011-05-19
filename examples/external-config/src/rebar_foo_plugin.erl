%% This module simulates a rebar plugin - we're excluding this file from the
%% dist, and it's for that (testing) purpose that it exists.
-module(rebar_foo_plugin).
-export([foo/2]).

foo(Config, _) ->
    io:format("Plugin foo called with ~p~n", [Config]),
    ok.
