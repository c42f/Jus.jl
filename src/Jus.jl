module Jus

using Match
using JSON3
using JSON3: StructTypes
using Base.Filesystem
using Match
using HTTP
using Generators
using Pkg
using DefaultApplication
using Sockets

import Base.@kwdef, Base.Iterators.flatten
import Base.Iterators.flatten

include("types.jl")
include("vars.jl")
include("server.jl")

export exec, serve, input, output, set_metadata, Config, present, start

verbose = false

strdefault(str, default) = str == "" ? default : str

function usage()
    print("""Usage: jus NAMESPACE [-v] [-s ADDR | -c ADDR [-x SECRET]] [CMD [ARGS...]]

NAMESPACE is this jus instance's namespace

-s ADDR     serve HTTP requests on ADDR if ADDR starts with '/', use a UNIX domain socket
-c ADDR     connect to ADDR using NAMESPACE
-x SECRET   use secret to prove ownership of NAMESPACE. If NAMESPACE does not yet exist,
            the server creates it and associates SECRET with it.
-i DIR      include dir to the http server file path
-e EXPR     evaluate Julia expression
-b TYPE     open browser on TYPE
-v          verbose

COMMANDS
set [[-c] [PATH VALUE] | [-m PATH]]...
  Set a variable, optionally creating it if it does not exist. NAMESPACE defaults to the
  current namespace.

  -c    create a variable
  -m    set only metadata for a variable (PATH should contain META -- see below)

  The format of PATH (without spaces) is
    NAME ['.' NAME]... [: META]
    or
    NAMESPACE '/' ID ['.' NAME]... [: META]

  NAMESPACE '/' ID defaults to ROOT/0.
  The name '?' means to create a new numbered child of NAMESPACE '/' ID.
  The name '?N' refers to the Nth variable created in this command (to help create trees)

  The format of META is
    NAME [',' META]...
    or
    NAME '=' VALUE [',' META]...

  Set returns a JSON list of ids the variables that were created:
    {"result": [id1, id2, ...]}

  COMMON META VALUE NAMES
  app       create an instance of the named application's object model
  path      the path from the parent's value to the corresponding value in the object model
            an empty path refers to the parent
  monitor   whether to monitor the value in the object model value is yes/no/true/false/on/off
  call      call a function on the value, optionally with a context object

get PATH...
  See set command for PATH format.

  returns values of requested variables:
    {"result": [value1, value2, ...]}

delete ID
  Remove a variable and all of its children

observe ID...
  receive updates whenever variables or their children change. Update format is
    {"update": [id1, name1, id2, name2, ...]}

  returns the ids and values for the given paths plus all of their descendants
    {"result": [id1, value1, id2, value2, ...]}
""")
    exit(1)
end

log(args...) = @info join(args)

function shutdown(config)
    println("SHUTTING DOWN")
end

function parseAddr(config::Config, s)
    m = match(r"^(([^:]+):)?([^:]+)$", s)
    config.host == m[2] ? "127.0.0.1" : m[2]
    config.port = parse(UInt16, m[3])
end

function abort(msg...)
    println(Base.stderr, msg...)
    exit(1)
end

output(ws; args...) = output(ws, args)
function output(ws, data)
    write(ws, JSON3.write(data))
    flush(ws)
    @debug("WROTE: $(JSON3.write(data))")
end

input(ws) = JSON3.read(readavailable(ws))

function client(config::Config)
    if config.namespace.secret === "" abort("Secret required") end
    @debug("CLIENT $(config.namespace) connecting to ws//$(config.host):$(config.port)")
    HTTP.WebSockets.open("ws://$(config.host):$(config.port)") do ws
        output(ws, (namespace = config.namespace, secret = config.namespace.secret))
        output(ws, config.args)
        result = JSON3.read(readavailable(ws)) # read one message
        @debug("RESULT: $(result)")
        if config.args[1] == "observe"
            @debug("READING UPDATES")
            while true
                result = JSON3.read(readavailable(ws))
                @debug("RESULT: $(result)")
            end
        end
    end
end

function exec(serverfunc, args::Vector{String}; config = Config())
    local browse = ""

    # name required -- only one instance per name allowed
    (length(args) === 0 || match(r"^-.*$", args[1]) !== nothing) && usage()
    config.serverfunc = serverfunc
    config.namespace.name = args[1]
    i = 2
    while i <= length(args)
        @match args[i] begin
            "-e" => Main.eval(Meta.parse(args[i += 1]))
            "-i" => add_file_dir(args[i += 1])
            "-v" => (config.verbose = true)
            "-x" => (config.namespace.secret = args[i += 1])
            "-c" => parseAddr(config, args[i += 1])
            "-b" => (browse = args[i += 1])
            "-s" => begin
                parseAddr(config, args[i += 1])
                config.server = true
            end
            unknown => begin
                @debug("MATCHED DEFAULT: $(args[i:end])")
                push!(config.args, args[i:end]...)
                i = length(args)
                break
            end
        end
        i += 1
    end
    atexit(()-> shutdown(config))
    config.server && browse != "" && present(config, browse)
    (config.server ? server : client)(config)
    config
end

"""
    start(port = 0, host = "0.0.0.0", type = Nothing)

Starts Jus in a new task on host and port (port 0 means pick a random port)
and, if given a type, opens a browser page editing the type.

Returns the config.
"""
function start(data = nothing; port = 0, host = nothing, dirs=[], async=true)
    for dir in dirs
        add_file_dir(dir)
    end
    config = Config()
    port, socket = host === nothing ? Sockets.listenany(port) : Sockets.listenany(IPv4(host), port)
    config.port = port
    config.host = getsockname(socket)[1]
    config.hostname = host
    println("HOST: $(config.host)")
    data !== Nothing && present(config, data)
    if async
        @async server(config, socket)
    else
        server(config, socket)
    end
    config
end

function present(config::Config, data)
    var = addvar(config, data)
    #make the connection track the variable so it cleans up on disconnect
    config.init_connection = con-> addvar(con, var)
    @async begin
        try
            sleep(0.5)
            DefaultApplication.open("http://$(confit.hostname):$(config.port)/shell.html?$(var.id)")
        catch err
            exit(1)
        end
    end
end
present(config::Config, type::Type) = present(config, "$(Base.parentmodule(type)).$type")
function present(config::Config, type::String)
    @async begin
        try
            sleep(0.5)
            DefaultApplication.open("http://$(config.hostname):$(config.port)/shell.html?@/0:create=$type")
        catch err
            exit(1)
        end
    end
end

changed(cfg::Config, var::Var) = get!(()-> Dict(), cfg.changes, var.id)[:set] = true
function changed(cfg::Config, var::Var, metaproperties...)
    push!(get!(()-> Set(), get!(()-> Dict(), cfg.changes, var.id), :metadata), metaproperties...)
end

set_var(cmd::VarCommand, value) = set_var(cmd, cmd.var, value)
set_var(cmd::VarCommand, name::Symbol, value) = set_var(cmd, cmd.var[name], value)
function set_var(cmd::VarCommand, var::Var, value)
    var.value = value
    changed(cmd.config, var)
end

delete_var(cmd::VarCommand) = delete_var(cmd, cmd.var)
delete_var(cmd::VarCommand, name::Symbol) = delete_var(cmd, cmd.var[name])
function delete_var(cmd::VarCommand, var::Var)
    if var.parent != EMPTYID
        parent = cmd.config[var.parent]
        if var.name != Symbol("")
            delete!(parent.namedchildren, var.name)
        else
            parent.indexedchildren = filter(c-> c !== var, parent.indexedchildren)
        end
        delete!(cmd.config.vars, var.id)
    end
    changes = get!(()-> Dict(), cmd.config.changes, var.id)
    delete!(changes, :set)
    delete!(changes, :metadata)
    changes[:delete] = true
end

set_metadata(cmd::VarCommand, name::Symbol, value) = set_metadata(cmd, cmd.var, name, value)
set_metadata(cmd::VarCommand, varname::Symbol, name::Symbol, value) =
    set_metadata(cmd, cmd.var[varname], name, value)
function set_metadata(cmd::VarCommand, var::Var, name::Symbol, value::AbstractString)
    if !haskey(var.metadata, name) || get(var.metadata, name, "") != value
        var.metadata[name] = value
        changed(cmd.config, var, name)
    end
end

"""
    route(parent_value, cmd)

Route a command, calling handle_child for each ancestor of the variable, starting with the root.
Returns the command.

See handle() for details on commands.
"""
function route(parent_value, cmd::VarCommand)
    path = cmd.path = []
    cur = cmd.var.parent
    while cur !== EMPTYID
        var = cmd.config[cur]
        push!(path, var)
        cur = var.parent
    end
    handle_route(parent_value, cmd)
end

# implemented recursively so developers can overrride it
# using the parent_value's type
function handle_route(parent_value, cmd::VarCommand)
    cmd.cancel && return cmd
    #println("@@@ HANDLE ROUTE $(parent_value), $(cmd)")
    if isempty(cmd.path)
        #println("@@@ FINAL HANDLE $(parent_value), $(cmd)")
        override(cmd, handle(parent_value, cmd))
    else
        var = cmd.path[1]
        cmd.path = @view cmd.path[2:end]
        cmd = override(cmd, handle_child(var, var.value, parent_value, cmd))
        cmd = override(cmd, handle_route(parent_value, cmd))
        override(cmd, finish_handle_child(var, var.value, parent_value, cmd))
    end
end

override(cmd::VarCommand, result) = result isa VarCommand ? result : cmd

"""
    handle_child(var, value, cmd, path)

Allows ancestor variables to alter or cancel commands.
`handle_child` can replace the given VarCommand by return a different one
See handle() for details on commands.
"""
handle_child(ancestor_var, ancestor, value, cmd) = nothing

"""
    finish_handle_child(var, value, cmd, path)

Allows ancestor variables to alter or cancel commands after they have been processed.
See handle() for details on commands.
"""
finish_handle_child(ancestor_var, ancestor, value, cmd) = nothing

"""
    handle(value, cmd::VarCommand{Command, Arg})

Base-level command routing.
Developers can specialize on value and cmd.

COMMANDS

  :metadata Set metadata for a variable. Arg will be a tuple with the metadata's name.
            initially sent before :set and :create
            NOTE: value is the PARENT VARIABLE'S value

  :set      Change the value of a variable. Initially called before :create.
            NOTE: value is the PARENT VARIABLE'S value

  :create   The variable has just been created (called after :metadata and :set)
            NOTE: value is the VARIABLE'S value

  :get      Determine the new value for a variable. By default, variables retain their values
            but handlers can change this behavior.
            NOTE: value is the PARENT VARIABLE'S value
"""
handle(value, cmd::VarCommand) = default_handle(value, cmd)

default_handle(value, cmd::VarCommand{:metadata}) = nothing

function default_handle(value, cmd::VarCommand{:metadata, (:create,)})
    cmd.creating && create_from_metadata(cmd)
end

function default_handle(value, cmd::VarCommand{:metadata, (:path,)})
    @debug("@@@ PATH METADATA: $(repr(cmd))")
    set_path_from_metadata(cmd)
end

function default_handle(value, cmd::VarCommand{:metadata, (:access,)})
    println("@@@ ACCESS METADATA: $(repr(cmd))")
    set_access_from_metadata(cmd.var)
end

function default_handle(value, cmd::VarCommand{:set})
    #println("@@@ BASIC SET $(cmd.var.id): $(repr(cmd))")
    #println("@@@@@@ VAR: $(cmd.var)")
    if isempty(cmd.var.path)
        cmd.var.internal_value = cmd.var.value = cmd.arg
        cmd.creating && changed(cmd.config, cmd.var)
        set_type(cmd)
    elseif cmd.var.writeable
        println("@@@@@@@@ SET PATH: $(cmd.var.path) OF $(cmd.var)")
        set_path(cmd)
    end
    !cmd.cancel && !cmd.var.action && changed(cmd.config, cmd.var)
end

function default_handle(value, cmd::VarCommand{:get})
    if has_path(cmd.var)
        get_path(cmd)
        if haskey(cmd.var.metadata, :transformerId)
            cur = cmd.var
            while cur.parent != EMPTYID
                cur = cmd.config[cur.parent]
                if haskey(cmd.var.metadata, :transformer)
                    cmd.var.value = transform(cur, cur.internal_value, cmd)
                    break
                end
            end
        end
    end
end

default_handle(value, cmd::VarCommand{:observe}) = nothing

default_handle(value, cmd::VarCommand{:create}) = nothing

transform(parent_var::Var, parent, cmd::VarCommand) = cmd.var.internal_value

end
