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

-compile(export_all).

%%-export([dist/2, distclean/2]).
%%-export([generate/2, clean/2]).

-define(DEBUG(Msg, Args),
    rebar_log:log(debug, "[~p] " ++ Msg, [?MODULE|Args])).

-define(WARN(Msg, Args),
    rebar_log:log(warn, "[~p] " ++ Msg, [?MODULE|Args])).

-record(assembly, {name, opts}).
-record(conf, {base, rebar, dist}).
-record(spec, {path, glob, target, mode, template}).
-record(entry, {spec, source, target, data, info}).

%%
%% Public API
%%

dist(Config, AppFile) ->
    %% AppName will be the default output filename
    rebar_config:set_global(skip_deps, 1),
    {App, DistConfig} = scope_config(AppFile, Config),
    dist(#conf{ base=App, rebar=Config, dist=DistConfig }).

distclean(Config, AppFile) ->
    {_, DistConfig} = scope_config(AppFile, Config),
    Outdir = outdir(DistConfig),
    rebar_file_utils:rm_rf(Outdir).

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
%% (Public) Utility functions used in read_conf as bindings
%%

glob(Expr) ->
    {glob, Expr}.

template({glob, Glob}) ->
    #spec{glob=Glob, template=true};
template(Path) ->
    #spec{path=Path, template=true}.

template({glob, Glob}, Target) ->
    #spec{glob=Glob, target=Target, template=true};
template(Path, Target) ->
    #spec{path=Path, target=Target, template=true}.

spec({glob, Glob}, Target) ->
    #spec{glob=Glob, target=Target};
spec(Path, Target) ->
    #spec{path=Path, target=Target}.

%%spec(Glob, Mode, Owner, Group) ->
%%    #spec{glob=Glob, mode={Mode, Owner, Group}}.

%%spec(Glob, Target, Mode, Owner, Group) ->
%%    #spec{glob=Glob, target=Target, mode={Mode, Owner, Group}}.



%%
%% Internal API
%%

outdir(Opts) ->
    proplists:get_value(outdir, Opts, "dist").

process_assembly(#assembly{name=Name, opts=Opts}) ->
    ?DEBUG("~p::Config = ~p~n", [Name, Opts]),
    Format = proplists:get_value(format, Opts, targz),
    Outdir = outdir(Opts),
    InclFiles = proplists:get_value(incl_files, Opts, []),
    InclDirs = proplists:get_value(incl_dirs, Opts, []),
    ExclFiles = flatten_specs(collect_dirs(
                            proplists:get_value(excl_files, Opts, []))),
    ExclDirs = flatten_specs(collect_dirs(
                            proplists:get_value(excl_dirs, Opts, []))),
    CopyDirs = lists:map(fun(I) -> filter(I, ExclDirs) end,
                         collect_dirs(InclDirs)),
    CopyFiles = lists:map(fun(I) -> filter(I, ExclFiles) end,
                          collect_files(InclFiles)),
    ?DEBUG("CopyDirs: ~p - CopyFiles: ~p~n", [CopyDirs, CopyFiles]),
    MergedFsEntries = merge_entries(CopyDirs, CopyFiles, Opts),
    ?DEBUG("MergedFsEntries: ~p~n", [MergedFsEntries]),
    generate_assembly(Format, Name, Outdir, MergedFsEntries).

generate_assembly(zip, Name, Outdir, MergedFsEntries) ->
    ensure_path(Outdir),
    Opts = case rebar_config:is_verbose() of
        true ->
            [verbose];
        _ ->
            []
    end,
    Filename = filename:join(Outdir, Name) ++ ".zip",
    ?DEBUG("Filename: ~p~n", [Filename]),
    %% TODO: we must *remove* any duplicate entries (prefix based)
    {ok, {_OutputFile, _Archive}} =
        zip:create(Filename, MergedFsEntries, Opts ++ [memory]),
    %% TODO: reconstruct the template entries in memory before writing to disk
    ?DEBUG("MergedFsEntries: ~p~n", [MergedFsEntries]),
    error;
generate_assembly(tar, Name, Outdir, MergedFsEntries) ->
    ensure_path(Outdir),
    Opts = case rebar_config:is_verbose() of
        true ->
            [write, compressed, verbose];
        _ ->
            [write, compressed]
    end,
    Filename = filename:join(Outdir, Name) ++ ".tar.gz",
    %% -record(entry, {spec, source, target, data, info}).
    Entries = lists:map(fun tar_entry/1, MergedFsEntries),
    ?DEBUG("Tar Entries: ~p~n", [Entries]),
    erl_tar:create(Filename, Entries, Opts).

%% TODO: to write a directory into the tar with a different name, we will need
%% to (recursively) copy it to a "work area" with the new name

tar_entry(#entry{source=Src, target=Targ, data=undefined,
                 info=#file_info{type=directory}}) when Src /= Targ ->
    {Targ, Src};
tar_entry(#entry{source=Src, target=undefined, data=undefined,
                 info=#file_info{type=directory}}) ->
    Src;
tar_entry(#entry{source=Src, target=Targ, data=undefined,
                 info=#file_info{type=regular}}) when Src == Targ ->
    Src;
tar_entry(#entry{source=Src, target=Targ, data=undefined,
                 info=#file_info{type=regular}}) when Src /= Targ ->
    {Targ, Src};
tar_entry(#entry{source=Src, target=Targ, data=Bin,
                 info=#file_info{type=regular}}) when Src /= Targ andalso
                                                      is_binary(Bin) ->
    {Targ, Bin}.

merge_entries(DirSpecs, FileSpecs, Opts) ->
    CopyDirs = flatten_specs(DirSpecs),
    CopyFiles = flatten_specs(FileSpecs),
    ExtraFiles = [ output_def(S, F) || {S, F} <- CopyFiles,
                           S#spec.template =/= true andalso
                           not( lists:any(prefix_of(F), CopyDirs) ) ],
    TemplatedFiles = [ {S, F} || {S, F} <- CopyFiles,
                                 S#spec.template =:= true ],
    ProcessedTemplates = merge_templates(TemplatedFiles, Opts),
    FirstDirs = [ output_def(S, F) || {S, F} <- CopyDirs ],
    lists:concat([FirstDirs, ExtraFiles, ProcessedTemplates]).

output_def(Spec, {File, Data}) ->
    output_def(Spec, File, Data);
output_def(Spec, File) ->
    output_def(Spec, File, undefined).

output_def(Spec, File, Data) ->
    {ok, FI} = file:read_file_info(File),
    case Spec#spec.target of
        undefined ->
            #entry{spec=Spec, source=File,
                   data=Data, target=File, info=FI};
        '_' ->
            #entry{spec=Spec, source=File,
                   data=Data, target=File, info=FI};
        Target ->
            case FI#file_info.type of
                regular ->
                    NewName = filename:join(Target, filename:basename(File)),
                    #entry{spec=Spec, source=File,
                           data=Data, target=NewName, info=FI};
                _ ->
                    #entry{spec=Spec, source=File, target=File, info=FI}
            end
    end.

prefix_of(F) ->
    fun(D) -> lists:prefix(D, F) end.

merge_templates(TemplatedFiles, Opts) ->
    Vars = case proplists:get_value(vars_file, Opts) of
        undefined ->
            dict:new();
        Path ->
            case file:consult(Path) of
                {error, _} ->
                    dict:new();
                {ok, Terms} ->
                    dict:from_list(Terms)
            end
    end,
    lists:map(fun(F) -> apply_template(F, Vars) end, TemplatedFiles).

apply_template({Spec, File}, Vars) ->
    {ok, Bin} = file:read_file(File),
    output_def(Spec, {File, rebar_templater:render(Bin, Vars)}).

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
process_files({Dir, #spec{glob=Glob}=Spec}) ->
    Files = rebar_utils:find_files(Dir, Glob) ++ filelib:wildcard(Glob),
    {Spec, Files};
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
    App = basename(),
    BaseConfig = rebar_config:get_list(Config, dist, []),
    {App, [{app, App}|merge_config(BaseConfig)]};
scope_config(AppFile, Config) ->
    App = rebar_app_utils:app_name(AppFile),
    BaseConfig = rebar_config:get_list(Config, dist, []),
    {App, [{app, App}|merge_config(BaseConfig)]}.

merge_config(BaseConfig) ->
    case lists:keyfind(config, 1, BaseConfig) of
        false ->
            BaseConfig;
        ConfigPath ->
            case read_conf(ConfigPath) of
               {ok, {dist, Terms}} ->
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

read_conf(File) ->
    Bs = erl_eval:new_bindings(),
    case file:path_open([rebar_utils:get_cwd()], File, [read]) of
    {ok,Fd,Full} ->
        case eval_stream(Fd, return, Bs) of
            {ok,R} ->
                file:close(Fd),
                {ok, R, Full};
            E1 ->
                file:close(Fd),
                E1
        end;
    E2 ->
        E2
    end.

config_fn_handler(Name, Arguments) ->
    apply(?MODULE, Name, Arguments).

eval_stream(Fd, Handling, Bs) ->
    eval_stream(Fd, Handling, 1, undefined, [], Bs).

eval_stream(Fd, H, Line, Last, E, Bs) ->
    eval_stream2(io:parse_erl_exprs(Fd, '', Line), Fd, H, Last, E, Bs).

eval_stream2({ok,Form,EndLine}, Fd, H, Last, E, Bs0) ->
    try erl_eval:exprs(Form, Bs0, {value, fun config_fn_handler/2}) of
        {value,V,Bs} ->
            eval_stream(Fd, H, EndLine, {V}, E, Bs)
    catch Class:Reason ->
        Error = {EndLine,?MODULE,{Class,Reason,erlang:get_stacktrace()}},
        eval_stream(Fd, H, EndLine, Last, [Error|E], Bs0)
    end;
eval_stream2({error,What,EndLine}, Fd, H, Last, E, Bs) ->
    eval_stream(Fd, H, EndLine, Last, [What | E], Bs);
eval_stream2({eof,EndLine}, _Fd, H, Last, E, _Bs) ->
    case {H, Last, E} of
    {return, {Val}, []} ->
        {ok, Val};
    {return, undefined, E} ->
        {error, hd(lists:reverse(E, [{EndLine,?MODULE,undefined_script}]))};
    {ignore, _, []} ->
        ok;
    {_, _, [_|_] = E} ->
        {error, hd(lists:reverse(E))}
    end.
