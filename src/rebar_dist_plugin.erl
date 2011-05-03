%% -----------------------------------------------------------------------------
%%
%% Rebar Dist Plugin
%%
%% Copyright (c) 2011 Tim Watson (watson.timothy@gmail.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -----------------------------------------------------------------------------
%% @author Tim Watson [http://hyperthunk.wordpress.com]
%% @copyright (c) Tim Watson, 2011
%% @since: April 2011
%%
%% @doc Rebar Dist Plugin.
%%
%% This plugin allows you to package up a (configurable) set of files into a
%% compressed archive (i.e. .tar.gz or .zip). The plugin's rebar configuration
%% supports wildcards in both relative and absolute paths for files and
%% directories, output path/file name and will allow you to make multiple files
%% if so required.
%%
%% The plugin exports a new `dist` command, an will also run in response to the
%% `generate` and `clean` commands, if configured to do so.
%% -----------------------------------------------------------------------------
-module(rebar_dist_plugin).

-include_lib("kernel/include/file.hrl").

-export([dist/2, distclean/2]).
-export([generate/2, clean/2]).

-define(DEBUG(Msg, Args),
    rebar_log:log(debug, "[~p] " ++ Msg, [?MODULE|Args])).

-define(WARN(Msg, Args),
    rebar_log:log(warn, "[~p] " ++ Msg, [?MODULE|Args])).

-record(assembly, {name, opts}).
-record(conf, {base, rebar, dist}).
-record(spec, {path, glob, target, mode, template}).

%%
%% Public API
%%

dist(Config, AppFile) ->
    %% AppName will be the default output filename
    {App, DistConfig} = scope_config(AppFile, Config),
    dist(#conf{ base=App, rebar=Config, dist=DistConfig }).

distclean(Config, _) ->
    rebar_log:log(debug, "Dist Plugin `distclean' ~p~n", [Config]),
    ok.

generate(Config, AppFile) ->
    rebar_log:log(debug, "Dist Plugin `generate' ~p~n", [Config]),
    Attach = rebar_config:get_local(Config, attach, []),
    case lists:member(generate, Attach) of
        true ->
            dist(Config, AppFile);
        false ->
            ok
    end.

clean(Config, AppFile) ->
    rebar_log:log(debug, "Dist Plugin `generate' ~p~n", [Config]),
    Attach = rebar_config:get_local(Config, attach, []),
    case lists:member(clean, Attach) of
        true ->
            distclean(Config, AppFile);
        false ->
            ok
    end.

dist(Conf) ->
    Results = [ process_assembly(A) || A <- find_assemblies(Conf) ],
    Errors = [R || R <- Results, R =/= ok],
    case (length(Errors) > 0) of
        true ->
            {error, Errors};
        false ->
            ok
    end.

%%
%% Internal API
%%

process_assembly(#assembly{name=Name, opts=Opts}) ->
    ?DEBUG("~p::Config = ~p~n", [Name, Opts]),
    Format = proplists:get_value(format, Opts, targz),
    Outdir = proplists:get_value(outdir, Opts, "dist"),
    InclFiles = proplists:get_value(incl_files, Opts, []),
    InclDirs = proplists:get_value(incl_dirs, Opts, []),
    ExclFiles = proplists:get_value(excl_files, Opts, []),
    ExclDirs = proplists:get_value(excl_dirs, Opts, []),
    CopyDirs = filter(collect_dirs(InclDirs),
                      flatten_specs(collect_dirs(ExclDirs))),
    CopyFiles = filter(collect_files(InclFiles),
                       flatten_specs(collect_files(ExclFiles))),
    MergedFsEntries = merge_entries(Format, CopyDirs, CopyFiles, Opts),
    generate_assembly(Format, Name, Outdir, MergedFsEntries).

generate_assembly(zip, Name, Outdir, MergedFsEntries) ->
    ensure_path(Outdir),
    Opts = case rebar_config:get_global(verbose, false) of
        true ->
            [verbose];
        false ->
            []
    end,
    Filename = filename:join(Outdir, Name) ++ ".zip",
    %% TODO: we must *remove* any duplicate entries (prefix based)
    {ok, {_OutputFile, _Archive}} = 
        zip:create(Filename, MergedFsEntries, Opts ++ [memory]),
    %% TODO: reconstruct the template entries in memory before writing to disk
    error;
generate_assembly(tar, Name, Outdir, MergedFsEntries) ->
    ensure_path(Outdir),
    Opts = case rebar_config:get_global(verbose, false) of
        true ->
            [write, compressed, verbose];
        false ->
            [write, compressed]
    end,
    Filename = filename:join(Outdir, Name) ++ ".tar.gz",
    erl_tar:create(Filename, MergedFsEntries, Opts).

merge_entries(Format, DirSpecs, FileSpecs, Opts) ->
    CopyDirs = flatten_specs(DirSpecs),
    CopyFiles = flatten_specs(FileSpecs),
    TemplatedFiles = [ {S, F} || {S, F} <- CopyFiles, S#spec.template =:= true ],
    SpecificFiles = [ output_def(S, F, Format) || {S, F} <- CopyFiles,
                           not lists:any(prefix_of(F), CopyDirs) andalso
                           S#spec.template =/= true ],
    ProcessedTemplates = merge_templates(TemplatedFiles, Format, Opts),
    lists:concat([CopyDirs, SpecificFiles, ProcessedTemplates]).

output_def(Spec, {File, Data}, Format) ->
    output_def(Spec, File, Data, Format);
output_def(Spec, File, Format) ->
    output_def(Spec, File, undefined, Format).

output_def(Spec, File, Data, _Format) ->
    {ok, FI} = file:read_file_info(File),
    _PathInArchive = case Spec#spec.target of
        undefined ->
            File;
        '_' ->
            File;
        Target ->
            case FI#file_info.type of
                regular ->
                    NewName = filename:join(Target, filename:basename(File)),
                    {File, Data, {rewrite, NewName}};
                _ ->
                    {File, {rewrite, Target}}
            end
    end.

prefix_of(F) ->
    fun(D) -> lists:prefix(D, F) end.

merge_templates(TemplatedFiles, Format, Opts) ->
    Vars = dict:from_list(proplists:get_value(vars_file, Opts, [])),
    lists:map(fun(F) -> apply_template(F, Vars, Format) end, TemplatedFiles).

apply_template({Spec, File}, Vars, Format) ->
    {ok, Bin} = file:read_file(File),
    output_def(Spec, {File, rebar_templater:render(Bin, Vars)}, Format).

flatten_specs([]) ->
    [];
flatten_specs([{Spec, Items}|Rest]) ->
    [{Spec, I} || I <- Items] ++ flatten_specs(Rest).

filter({Spec, Incl}, Excl) ->
    {In, Out} = lists:partition(fun(I) -> should_include(I, Excl) end, Incl),
    ?DEBUG("Excluding ~p~n", [Out]),
    {Spec, In}.

should_include(Incl, Exclusions) ->
    not lists:any(fun(Ex) -> lists:prefix(Ex, Incl) end, Exclusions).

collect_dirs(Includes) ->
    lists:map(fun process_dir/1, Includes).

collect_files(Includes) ->
    Cwd = rebar_utils:get_cwd(),
    Dirs = lists:duplicate(length(Includes), Cwd),
    lists:map(fun process_files/1, lists:zip(Dirs, Includes)).

%% TODO: handle *mode* by doing a(ny) chmod/chown/chgrp in a work directory

%% TODO: unify process_files and process_dir
%% TODO: rename process_dir => process_dirs

process_files({_Dir, #spec{path=Path, glob=undefined}=Spec}) ->
    {Spec, Path};
process_files({Dir, #spec{glob=Regex}=Spec}) ->
    {Spec, rebar_utils:find_files(Dir, Regex)};
process_files({Dir, PathExpr}) when is_list(PathExpr) ->
    process_files({Dir, #spec{glob=PathExpr}}).

process_dir(#spec{path=Path, glob=undefined}=Spec) ->
    {Spec, Path};
process_dir(#spec{glob=Glob}=Spec) ->
    {Spec, filelib:wildcard(Glob)};
process_dir(PathExpr) when is_list(PathExpr) ->
    process_dir(#spec{glob=PathExpr}).

ensure_path(Dir) ->
    rebar_utils:ensure_dir(Dir),
    ok = case filelib:is_dir(Dir) of
        true ->
            ok;
        false ->
            file:make_dir(Dir)
    end,
    Dir.

find_assemblies(#conf{ base=Base, dist=DistConfig }) ->
    case lists:filter(fun(X) -> element(1, X) == assembly end, DistConfig) of
        [] ->
            %% TODO: infer an assembly from *top level* config
            [#assembly{name=Base, opts=DistConfig}];
        Assemblies ->
            Assemblies
    end.

scope_config(undefined, Config) ->
    App = {app, basename()},
    BaseConfig = rebar_config:get_list(Config, dist, []),
    {App, [App|merge_config(BaseConfig)]};
scope_config(AppFile, Config) ->
    App = {app, rebar_app_utils:app_name(AppFile)},
    BaseConfig = rebar_config:get_list(Config, dist, []),
    {App, [App|merge_config(BaseConfig)]}.

merge_config(BaseConfig) ->
    case lists:keyfind(config, 1, BaseConfig) of
        false ->
            BaseConfig;
        ConfigPath ->
            case file:consult(ConfigPath) of
               {ok, Terms} ->
                   %% all non-assembly members are ignored
                   Assemblies = [ A || A <- Terms, element(1, A) =:= assembly ],
                   lists:foldl(fun merge_assemblies/2, BaseConfig, Assemblies);
               Other ->
                   ?WARN("Failed to load ~s: ~p\n", [ConfigPath, Other]),
                   BaseConfig
           end
    end.

merge_assemblies(E, Acc) ->
    lists:keyreplace(E#assembly.name, 2, Acc, E).

basename() ->
    filename:basename(rebar_utils:get_cwd()).
