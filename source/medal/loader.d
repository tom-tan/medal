/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.loader;

import dyaml : Node;

import medal.config : Config;
import medal.transition.core;

import std.typecons : Tuple;

///
Transition loadTransition(Node node, string file) @safe
{
    import medal.exception : loadEnforce, LoadError;

    auto type = (*loadEnforce("type" in node,
                              "`type` field is needed for transitions",
                              node, file)).get!string;
    switch(type)
    {
    case "shell":
        return loadShellCommandTransition(node, file);
    case "network":
        return loadNetworkTransition(node, file);
    case "invocation":
        return loadInvocationTransition(node, file);
    default:
        import std.format : format;
        throw new LoadError(format!"Unknown type: `%s`"(type), node, file);
    }
}

///
unittest
{
    import dyaml : Loader;
    import medal.transition.shell : ShellCommandTransition;

    enum inpStr = q"EOS
    name: echo
    type: shell
    out:
      - place: ret
        pattern: RETURN
    command: true
EOS";
    auto trRoot = Loader.fromString(inpStr).load;
    auto tr = loadTransition(trRoot, "");
    assert(cast(ShellCommandTransition)tr);
}

///
Transition loadShellCommandTransition(Node node, string file) @safe
in("type" in node)
in(node["type"].get!string == "shell")
do
{
    import medal.exception : loadEnforce;
    import medal.transition.shell : ShellCommandTransition;
    import std.range : empty;

    auto name = "name" in node ? node["name"].get!string : "";

    auto g = "in" in node ? loadGuard(node["in"], file) : Guard.init;

    auto aef = "out" in node ? loadArcExpressionFunction(node["out"], file)
                             : ArcExpressionFunction.init;

    auto cmdNode = *loadEnforce("command" in node,
                                "`command` field is necessary for shell transitions",
                                node, file);
    auto command = cmdNode.get!string;
    enforceValidCommand(command, g, aef, cmdNode, file);

    return new ShellCommandTransition(name, command, g, aef);
}

void enforceValidCommand(string cmd, Guard g, ArcExpressionFunction aef, Node node, string file) @safe
{
    import medal.exception : loadEnforce;
    
    import std.algorithm : canFind;
    import std.array : array;
    import std.format : format;
    import std.range : empty;
    import std.regex : ctRegex, matchAll, matchFirst;

    auto gPlaces = g.byKey.array;
    auto aefPlaces = aef.byKey.array;

    loadEnforce(!cmd.empty, "`command` field should not be an empty string",
                node, file);

    foreach(m; cmd.matchAll(ctRegex!(r"~(~~)*\(([^)]+)\)", "m")))
    {
        auto pl = Place(m[2]);
        if (auto p = gPlaces.canFind(pl))
        {
            continue;
        }
        else if (aefPlaces.canFind(pl))
        {
            loadEnforce(aef[pl].type == PatternType.File,
                        format!"Refering the output place `%s` that is not `FILE`"(pl),
                        node, file);
        }
        else
        {
            import medal.exception : LoadError;
            throw new LoadError(format!"Invalid place `%s`"(pl), node, file);
        }
    }
    if (cmd.matchFirst(ctRegex!(r"\$\(.+\)", "m")) ||
        cmd.matchFirst(ctRegex!(r"`.+`", "m")))
    {
        import medal.logger : sharedLog;
        import std.json : JSONValue;
        JSONValue msg;
        msg["sender"] = "medal.loader";
        msg["message"] = "Command substitutions may hide unintended execution failures";
        msg["file"] = file;
        sharedLog.warning(msg);
    }
}

///
Transition loadNetworkTransition(Node node, string file) @safe
in("type" in node)
in(node["type"].get!string == "network")
do
{
    import medal.exception : loadEnforce;
    import medal.transition.network : NetworkTransition;

    import std.algorithm : map;
    import std.array : array;
    import std.range : empty;

    loadEnforce("configurations" !in node,
                "Invalid field `configurations`; did you mean `configuration`?",
                node, file);
    auto con = "configuration" in node ? loadConfig(node, file) : Config.init;

    loadEnforce(con.tmpdir.empty, "`tmpdir` field is not valid in network transitions",
                node["configuration"]["tmpdir"], file);
    loadEnforce(con.workdir.empty, "`workdir` field is not valid in network transitions",
                node["configuration"]["workdir"], file);

    auto name = "name" in node ? node["name"].get!string : "";

    loadEnforce("transition" !in node,
                "Invalid field `transition`; did you mean `transitions`?",
                node, file);
    auto trsNode = *loadEnforce("transitions" in node,
                                "`transitions` field is needed in network transitions",
                                node, file);
    auto trs = trsNode.sequence
                      .map!(n => loadTransition(n, file))
                      .array;
    loadEnforce(!trs.empty, "at least one transition is needed in `transitions` fields",
                trsNode, file);

    auto g1 = "in" in node ? loadGuard(node["in"], file) : Guard.init;

    auto g2 = "out" in node ? loadGuard(node["out"], file) : Guard.init;
    return new NetworkTransition(name, g1, g2, trs, [], [], [], con);
}

///
Transition loadInvocationTransition(Node node, string file) @safe
in("type" in node)
in(node["type"].get!string == "invocation")
do
{
    import dyaml : Loader;

    import medal.exception : loadEnforce;
    import medal.transition.network : InvocationTransition;

    import std.file : exists;
    import std.format : format;
    import std.path : buildPath, dirName;

    loadEnforce("configurations" !in node,
                "Invalid field `configurations`; did you mean `configuration`?",
                node, file);
    auto con = "configuration" in node ? loadConfig(node, file) : Config.init;

    auto name = "name" in node ? node["name"].get!string : "";

    auto subFileNode = *loadEnforce("use" in node,
                                    "`use` field is needed in invocation transitions",
                                    node, file);
    auto subFile = buildPath(file.dirName, subFileNode.get!string);
    loadEnforce(subFile.exists, format!"Subnetwork file not found: `%s`"(subFile),
                subFileNode, file);
    auto subNode = Loader.fromFile(subFile).load;
    auto tr = loadTransition(subNode, subFile);

    auto inode = loadEnforce("in" in node, "`in` field is needed in invocation transitions",
                             node, file);
    auto itpl = loadPortGuard(*inode, file);
    enforceInPortIsValid(itpl[1], tr.guard, *inode, file);

    auto onode = loadEnforce("out" in node, "`out` field is needed in invocation transitions",
                             node, file);
    auto oPort = loadOutputPort(*onode, file);
    enforceOutPortIsValid(oPort, tr.arcExpFun, *onode, file);

    return new InvocationTransition(name, itpl[0], itpl[1], oPort, tr, con);
}

void enforceInPortIsValid(in Place[Place] ports, in Guard guard, Node node, string file) @safe
{
    import medal.exception : loadEnforce;

    import std.algorithm : map, setDifference, sort;
    import std.array : array;
    import std.format : format;

    auto portPlaces = ports.byValue
                           .map!"a.name.dup"
                           .array
                           .sort()
                           .array;
    auto guardPlaces = guard.byKey
                            .map!"a.name"
                            .array
                            .sort()
                            .array;
    auto pg = setDifference(portPlaces, guardPlaces);
    loadEnforce(pg.empty, format!"Ports to non-existent places: %-(%s, %)"(pg), node, file);

    auto gp = setDifference(guardPlaces, portPlaces);
    loadEnforce(gp.empty, format!"Missing ports to: %-(%s, %)"(gp), node, file);
}

void enforceOutPortIsValid(in Place[Place] ports, ArcExpressionFunction aef, Node node, string file) @safe
{
    import medal.exception : loadEnforce;

    import std.algorithm : map, setDifference, sort;
    import std.array : array;
    import std.format : format;

    auto portPlaces = ports.byKey
                           .map!"a.name.dup"
                           .array
                           .sort()
                           .array;
    auto aefPlaces = aef.byKey
                        .map!"a.name"
                        .array
                        .sort()
                        .array;
    auto pa = setDifference(portPlaces, aefPlaces);
    loadEnforce(pa.empty, format!"Ports from non-existent places: %-(%s, %)"(pa), node, file);
}

///
Guard loadGuard(Node node, string file) @safe
{
    import medal.exception : loadEnforce;

    import std.algorithm : map;
    import std.array : assocArray;
    import std.exception : assumeUnique;
    import std.typecons : tuple;

    auto pats = node.sequence
                    .map!((n) {
                        auto pl = loadPlace(*loadEnforce("place" in n, "`place` field is needed",
                                                         n, file));
                        auto pat = (*loadEnforce("pattern" in n, "`pattern` field is needed",
                                                 n, file)).get!string;
                        return tuple(pl, InputPattern(pat));
                    })
                    .assocArray;
    return () @trusted { return pats.assumeUnique; }();
}

Tuple!(Guard, immutable Place[Place]) loadPortGuard(Node node, string file) @trusted
{
    import medal.exception : loadEnforce;

    import std.exception : assumeUnique;
    import std.typecons : tuple;

    InputPattern[Place] guard;
    Place[Place] mapping;
    foreach(Node n; node)
    {
        auto pl = loadPlace(*loadEnforce("place" in n, "`place` field is needed", n, file));
        auto pat = InputPattern((*loadEnforce("pattern" in n, "`pattern` field is needed", n, file)).get!string);
        auto p = loadPlace(*loadEnforce("port-to" in n, "`port-to` field is needed", n, file));
        guard[pl] = pat;
        mapping[pl] = p;
    }
    return tuple(guard.assumeUnique, mapping.assumeUnique);
}

immutable(Place[Place]) loadOutputPort(Node node, string file) @trusted
{
    import medal.exception : loadEnforce;

    import std.algorithm : map;
    import std.array : assocArray;
    import std.exception : assumeUnique;
    import std.typecons : tuple;

    auto port = node.sequence
                    .map!((n) {
                        auto from = loadPlace(*loadEnforce("place" in n, "`place` field is needed", n, file));
                        auto to = loadPlace(*loadEnforce("port-to" in n, "`port-to` field is needed", n, file));
                        return tuple(from, to);
                    })
                    .assocArray;
    return port.assumeUnique;
}

///
unittest
{
    import dyaml : Loader;

    enum inpStr = q"EOS
    - place: pl
      pattern: constant-value
EOS";
    auto root = Loader.fromString(inpStr).load;
    auto g = loadGuard(root, "dummy.yml");
    assert(g == cast(immutable)[Place("pl"): InputPattern("constant-value")]);
}

///
ArcExpressionFunction loadArcExpressionFunction(Node node, string file) @safe
{
    import medal.exception : loadEnforce;

    import std.algorithm : map;
    import std.array : assocArray;
    import std.exception : assumeUnique;
    import std.typecons : tuple;

    auto pats = node.sequence
                    .map!((n) {
                        auto pl = loadPlace(*loadEnforce("place" in n, "`place` field is needed", n, file));
                        auto pat = (*loadEnforce("pattern" in n, "`pattern` field is needed", n, file)).get!string;
                        return tuple(pl, OutputPattern(pat));
                    })
                    .assocArray;
    return () @trusted { return pats.assumeUnique; }();
}

///
BindingElement loadBindingElement(Node node, string file) @safe
{
    import std.algorithm : map;
    import std.array : assocArray;
    import std.exception : assumeUnique;
    import std.typecons : tuple;

    auto tokenElems = node.mapping
                          .map!(p => tuple(loadPlace(p.key),
                                           new Token(p.value.get!string)))
                          .assocArray;
    return new BindingElement(() @trusted { 
        return tokenElems.assumeUnique; 
    }());
}

///
Config loadConfig(Node node, string file) @safe
in("configuration" in node)
{
    import medal.exception : loadEnforce;

    import std.algorithm : canFind;

    auto n = node["configuration"];
    string tag;
    if (auto t = "tag" in n)
    {
        tag = t.get!string;
    }

    string workdir;
    if (auto wdir = "workdir" in n)
    {
        workdir = wdir.get!string;
        loadEnforce(!workdir.canFind(".."), "`..` is not allowed in `workdir`",
                    *wdir, file);
    }

    string tmpdir;
    if (auto tdir = "tmpdir" in n)
    {
        import std.algorithm : startsWith;

        tmpdir = tdir.get!string;
        loadEnforce(!tmpdir.canFind(".."), "`..` is not allowed in `tmpdir`",
                    *tdir, file);
        loadEnforce(tmpdir.startsWith("~(tmpdir)"), "`tmpdir` should be in the parent `tmpdir`",
                    *tdir, file);
    }

    string[string] environment;
    loadEnforce("environment" !in n, "Invalid field `environment`; did you mean `environments`?",
                n, file);
    if (auto env = "environments" in n)
    {
        import std.algorithm : map;
        import std.array : assocArray;
        import std.typecons : tuple;

        environment = env.sequence.map!((Node nn) {
            return tuple((*loadEnforce("name" in nn, "`name` field is needed", nn, file)).get!string,
                         (*loadEnforce("value" in nn, "`value` field is needed", nn, file)).get!string);
        }).assocArray;
    }

    typeof(return) ret = { 
        tag: tag, 
        environment: () @trusted {
            import std.exception : assumeUnique;
            return environment.assumeUnique;
        }(),
        workdir: workdir,
        tmpdir: tmpdir,
    };
    return ret;
}

Place loadPlace(Node node) @safe
{
    import medal.exception : loadEnforce;

    import std.algorithm : endsWith, startsWith;
    import std.format : format;
    import std.string : indexOfAny;

    enum prohibited = r"/\ '`$(){}[]:;*!?|<>#,"~'"'~'\0'~'\n';

    auto pl = node.get!string;

    auto idx = pl.indexOfAny(prohibited);
    loadEnforce(idx == -1, format!"Invalid charactter `%s` was found in the place name `%s`"(pl[idx], pl), node, "");

    loadEnforce(pl != "." && pl != ".." && pl != "~",
                format!"Invalid place name `%s`: its name is not allowed in medal"(pl), node, "");
    
    loadEnforce(!pl.startsWith("."), format!"Invalid place name `%s`: it should not start with `.`"(pl), node, "");
    loadEnforce(!pl.startsWith("-"), format!"Invalid place name `%s`: it should not start with `-`"(pl), node, "");
    loadEnforce(!pl.endsWith("&"), format!"Invalid place name `%s`: it should not end with `&`"(pl), node, "");

    return Place(pl);
}
