const NUM = r"^[0-9]+$"
const NAME = r"^\pL\p{Xan}*$"

const moduledir = pathof(Jus)
const pkgdir = moduledir !== nothing ? dirname(moduledir) : pwd()
const FILE_PATH = [joinpath(pkgdir, "html")]

function resolve(cmd::JusCmd, vars, str)
    if str == "?"
        ID(cmd)
    elseif (m = match(REF, str)) !== nothing
        vars[m[1]].id
    elseif match(r"^[0-9]+$", str) !== nothing
        parse(Int, str)
    elseif (m = match(PATH_COMPONENT, str)) !== nothing
        ID(m[1] == "@" ? cmd.namespace : m[1], parse(UInt, m[2]))
    else
        Symbol(str)
    end
end

const PATH_METADATA = r"^([^:]*)(?::(.*))?$"

function findvar(cmd::JusCmd, create, vars, path, metadata::Union{Nothing, Dict{Symbol}} = nothing, value = nothing)
    m = match(PATH_METADATA, path)
    if m[2] !== nothing
        path = m[1]
        metadata = parsemetadata(m[2], metadata)
    end
    path = split(path)
    @debug("PATH: $(path)")
    components = map(c-> resolve(cmd, vars, c), path)
    @debug("COMPONENTS: $(components)")
    last = components[end]
    if length(components) > 1 && components[1] isa ID
        parent = components[1]
        components = components[2:end - 1]
    else
        parent = EMPTYID
        components = components[1:end - 1]
    end
    @debug("PARENT COMPONENTS: $(repr(components))")
    @debug("LAST: $(repr(last))")
    for (i, v) in enumerate(components) # path should only be names and numbers
        isemptyid(v) && throw("'?' in the middle of $(path)")
        v isa ID && throw("ID in the middle of $(path)")
        parent == EMPTYID && throw("No parent variable for path $(path)")
        parent = cmd.config[parent][v].id
    end
    metadata === nothing && (metadata = Dict{Symbol, AbstractString}())
    @debug("PARENT: $(repr(parent))")
    @debug("CHECKING LAST...")
    if isemptyid(last)
        !create && throw("'?' without -c")
        parent != EMPTYID && throw("'?' at the end of path: $(path)")
        addvar(cmd, parent, Symbol(""), last, value, metadata), true
    elseif last isa ID
        parent != EMPTYID && throw("ID at the end of path: $(path)")
        cmd.config[last], false
    elseif parent == EMPTYID
        throw("Attempt to get path with no parent, path: $(path)")
    elseif create && last isa Union{Symbol, Number} && !haskey(cmd.config[parent], last)
        addvar(cmd, parent, last, ID(cmd), value, metadata), true
    elseif create
        throw("ERROR, attempt to create a variable that already exists: $(path)")
    else
        @debug("PATH -> $(parent).$(repr(last))")
        @debug("PARENT: $(repr(cmd.config[parent]))")
        cmd.config[parent][last], false
    end
end

function command(cmd::JusCmd{:set})
    local new = []
    local vars = []
    local creating
    local metadata
    local observing
    function newset()
        creating = false
        observing = false
        metadata = Dict{Symbol, AbstractString}()
    end

    @debug("@ SET (FRED 6): $(cmd.args)")
    pos = 1
    newset()
    while pos <= length(cmd.args)
        arg = cmd.args[pos]
        if arg == "-c"
            creating = true
        elseif arg == "-m"
            metadata[cmd.args[pos + 1]] = metadata[pos + 2]
            pos += 2
        else
            value = cmd.args[pos + 1]
            var, creating = findvar(cmd, creating, vars, cmd.args[pos], metadata, value)
            creating && haskey(var.metadata, :observe) && push!(connection(cmd).observing, var.id)
            @debug("FOUND VARIABLE: $(var)")
            creating && push!(new, var)
            parentvalue = var.parent == EMPTYID ? nothing : cmd.config[var.parent].value
            try
                pval = var.parent != EMPTYID ? parent_value(cmd.config, var) : nothing
                println("%%%\n%%% SETTING VARIABLE ($(pval)).$(var) FROM $(var.internal_value) TO $(value)")
                route(parentvalue, VarCommand(cmd, :set, (), var; arg = creating ? var.value : value, creating))
            catch err
                if err isa CmdException && err.type == :path
                    @debug "Error refreshing variable $(var)" exception=(err, catch_backtrace())
                    cmd.cancel = true
                else
                    rethrow(err)
                end
            end
            !cmd.cancel && push!(vars, var)
            newset()
            pos += 1
        end
        pos += 1
    end
    output(cmd; result = map(v-> json(cmd, v.id), new))
end

function command(cmd::JusCmd{:get})
    vars = []
    @debug("@ GET ARGS: $(cmd.args)")
    for path in cmd.args
        var, _ = findvar(cmd, false, vars, path)
        push!(vars, var)
    end
    output(cmd, result = [flatten(map(v-> (json(cmd, v.id), json(cmd, v.value)), vars))...])
end

function command(cmd::JusCmd{:observe})
    vars = []
    for path in cmd.args
        var, _ = findvar(cmd, false, vars, path)
        push!(vars, var.id)
    end
    @debug("@ OBSERVE ARGS: $(cmd.args)")
    union!(connection(cmd).observing, vars)
    @debug("OBSERVED VARS: $(repr(map(v-> v.id, allvars(cmd.config, connection(cmd).observing...))))")
    observed = [flatten(map(id-> [json(id), cmd.config[id].value], [connection(cmd).observing...]))...]
    @debug("OBSERVED: $(repr(observed))")
    for id in vars
        var = cmd.config[id]
        route(var.value, VarCommand(cmd, :observe, (), var))
    end
    output(cmd,
           result = [],
           update = Dict(json(cmd, vid) => (
               set = json(cmd, cmd.config[vid].value),
               metadata = cmd.config[vid].metadata
           ) for vid in connection(cmd).observing))
end

function output(cmd::JusCmd; data...)
    con = connection(cmd)
    con.pending_result = merge(con.pending_result, (; data...))
end

function finish_command(cmd::JusCmd)
    con = connection(cmd)
    println("PENDING RESULT: $(con.pending_result)")
    if haskey(con.pending_result, :result)
        refresh(cmd)
        observe(cmd)
        con.refresh_queued = false
    elseif !con.refresh_queued
        con.refresh_queued = true
        @async begin
            try
                sleep(0.2)
                #this could have been preempted by a command
                if con.refresh_queued
                    refresh(cmd)
                    observe(cmd)
                    con.refresh_queued = false
                end
            catch err
                exit(1)
            end
        end
    end
end

function observe(cmd::JusCmd)
    config = cmd.config
    isempty(config.changes) && return send_output(connection(cmd))
    for (_, connection) in config.connections
        @debug("CHECKING CONNECTION OBSERVING: $(repr(connection.observing))")
        changes = filter(e-> within(config, e[1], connection.observing), config.changes)
        if !isempty(changes)
            fmt = Dict()
            for (id, c) in changes
                var = config[id]
                if haskey(c, :set)
                    c[:set] = json(config, connection, var.value)
                end
                if haskey(c, :metadata)
                    c[:metadata] = Dict(m => var.metadata[m] for m in c[:metadata])
                end
                fmt[json(connection, id)] = Dict{Symbol, Any}(c...)
            end
            output(cmd, update = fmt)
        end
        send_output(connection)
    end
    config.changes = Dict()
end

function send_output(con::Connection)
    if con.pending_result != (;)
        output(con.ws, con.pending_result)
        con.pending_result = (;)
    end
end

function refresh(cmd::JusCmd)
    for (_, v) in cmd.config.vars
        try
            v.parent == EMPTYID && refresh(cmd, v)
        catch err
            @error "Error refreshing" exception=(err, catch_backtrace())
        end
    end
end

function refresh(cmd::JusCmd, var::Var)
    if has_path(var) && var.readable
        parent = parent_value(cmd.config, var)
        if parent !== nothing
            old = var.json_value
            var.refresh_exception = nothing
            try
                route(parent, VarCommand(:get, (); var, config = cmd.config, connection = connection(cmd)))
                old !== var.json_value && changed(cmd.config, var)
            catch err
                var.refresh_exception = err
                var.error_count += 1
                refresh_error(var, err, catch_backtrace())
            end
        end
    end
    for (_, v) in var.namedchildren
        refresh(cmd, v)
    end
    for v in var.indexedchildren
        refresh(cmd, v)
    end
end

"""
    refresh_error

Handle errors during refresh. Log path errors at the debug level.
"""
refresh_error(var::Var, ex::CmdException{:path}, bt) = @debug "Error refreshing variable $(var)" exception=(ex, bt)
refresh_error(var::Var, ex, bt) = @error "Error refreshing variable $(var)" exception=(ex, bt)

function serve(config::Config, ws)
    (; namespace, secret) = input(ws)
    if haskey(config.namespaces, namespace)
        if config.namespaces[namespace].secret !== secret
            @debug("Bad attempt to connect for $(namespace)")
            output(ws, error = "Wrong secret for $(namespace)")
            return
        end
    else
        config.namespaces[namespace] = Namespace(; name=namespace, secret)
    end
    con = Connection(; ws, namespace)
    config.connections[ws] = con
    config.init_connection(con)
    @debug("Connection for $(namespace)")
    while !eof(ws)
        string="unknown"
        try
            !isopen(ws) && break
            string = readavailable(ws)
            isempty(string) && continue
            cmd = JSON3.read(string, Vector)
            jcmd = JusCmd(config, ws, namespace, cmd)
            command(jcmd)
            finish_command(jcmd)
        catch err
            if !(err isa Base.IOError || err isa HTTP.WebSockets.WebSocketError)
                err isa ArgumentError && println(err)
                @error "Error handling comand $(String(string)) $(err)" exception=(err, catch_backtrace())
            end
            break
        end
    end
    close(config, con)
    put!(config.connections[ws].stop, true)
    @debug("CLIENT CLOSED: $(repr(namespace))")
end

function close(config::Config, con::Connection)
    Base.close(con.ws)
    for v in con.vars
        delete!(config.vars, v.id)
        delete!(config.changes, v.id)
    end
    delete!(config.connections, con.ws)
end

const FILE_EXT_PAT = r"^(.*)\.([^.]*)$"

const MIME_TYPES_FOR_EXTENSIONS = Dict(
    "js" => "text/javascript",
    "mjs" => "text/javascript",
    "css" => "text/css",
    "html" => "text/html",
    "png" => "image/png",
    "jpg" => "image/jpg",
    "gif" => "image/gif",
)

function mime_type(filename::AbstractString)
    m = match(FILE_EXT_PAT, filename)
    m === nothing && throw("Unknown MIME type for filename $(filename)")
    _, ext = m
    return get(MIME_TYPES_FOR_EXTENSIONS, ext) do
        throw("Unknown MIME type for filename $(filename) with extension $(ext)")
    end
end

add_file_dir(dirname) = push!(FILE_PATH, realpath(dirname))

function find_file(path)
    for dir in FILE_PATH
        dpath = joinpath(dir, path)
        println("TRYING PATH $dpath")
        if isdir(dpath)
            return :directory, dpath
        elseif isfile(dpath)
            return :file, dpath
        end
    end
    return :missing, path
end

"""
    serve_file

taken from [yig's file server](https://gist.github.com/yig/f65e86b7730019d4060449f24342fcb4)
enhanced to handle mime types
"""
function serve_file(req::HTTP.Request)
    ## If it's not a path inside the jail (current working directory), return a 403.
    jail = realpath(FILE_PATH[1])
    # println( "Jail path: ", jail )
        
    ## Convert the request path to a real path (remove symlinks, remove . and ..)
    ## UPDATE: realpath() assumes that the input points to something that exists.
    ##         We can't use it, since we don't know if the requested path exists.
    ##         We'll use normpath() instead.
    ## Requests start with "/" referring to the server as the root.
    target = replace(req.target, r"^([^?]*)\?.*"=> s"\1")
    @assert length(target) > 0 && target[1] == '/'
    ## Drop the leading "/".
    request_path = normpath(joinpath(jail, target[2:end]))
    ## Convert it to a relative path.
    relative_path = relpath(request_path, jail)
    println("Requested path: ", request_path)
    println("Relative path: ", relative_path)
    ## Return forbidden if the request is above the current working directory.
    length(relative_path) > 0 && splitpath(relative_path)[1] == ".." &&
        @show return HTTP.Response(403)
    type, filepath = find_file(relative_path)
    ## Return not implemented if the request is for a directory.
    if type == :directory
        ## Is there an index.html?
        index = joinpath(filepath, "index.html")
        if isfile(index)
            HTTP.Response(200, ["Content-Type" => mime_type(target)], body = read(index))
        else
            @show HTTP.Response(501)
        end
        ## Return the contents for a file.
    elseif type == :file
        HTTP.Response(200, ["Content-Type" => mime_type(target)], body = read(filepath))
    else
        ## If it's not a file, return a 404.
        @show HTTP.Response(404)
    end
end

function server(config::Config, socket = nothing)
    router = HTTP.Router()
    function handle_request(http)
        if http.message.target == "/ws"
            HTTP.WebSockets.upgrade(http) do ws
                config.serverfunc(config, ws)
            end
        else
            HTTP.handle(router, http)
        end
    end

    println("SERVER ON $(config.host):$(config.port)")
    HTTP.@register(router, "GET", "/ws", r-> serve_websocket(config, r))
    HTTP.@register(router, "GET", "/", serve_file)
    if socket === nothing
        HTTP.listen(handle_request, config.host, config.port)
    else
        HTTP.listen(handle_request; server=socket)
    end
    @debug("HTTP SERVER FINISHED")
end
