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
Transition loadTransition(Node node) @safe
{
    import medal.exception : loadEnforce, LoadError;

    auto type = (*loadEnforce("type" in node,
                              "`type` field is needed for transitions",
                              node)).get!string;
    switch(type)
    {
    case "shell":
        return loadShellCommandTransition(node);
    case "network":
        return loadNetworkTransition(node);
    case "invocation":
        return loadInvocationTransition(node);
    default:
        import std.format : format;
        throw new LoadError(format!"Unknown type: `%s`"(type), node);
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
    auto tr = loadTransition(trRoot);
    assert(cast(ShellCommandTransition)tr);
}

///
Transition loadShellCommandTransition(Node node) @safe
in("type" in node)
in(node["type"].get!string == "shell")
do
{
    import medal.exception : loadEnforce;
    import medal.transition.shell : ShellCommandTransition;
    import std.range : empty;

    auto name = "name" in node ? node["name"].get!string : "";

    auto g = "in" in node ? loadGuard(node["in"]) : Guard.init;

    auto aef = "out" in node ? loadArcExpressionFunction(node["out"])
                             : ArcExpressionFunction.init;
    enforceValidAEF("out" in node ? node["out"] : Node((Node[]).init),
                    "in" in node ? node["in"] : Node((Node[]).init));

    auto cmdNode = *loadEnforce("command" in node,
                                "`command` field is necessary for shell transitions",
                                node);
    auto command = cmdNode.get!string;
    enforceValidCommand(command, g, aef, cmdNode);

    return new ShellCommandTransition(name, command, g, aef);
}

void enforceValidAEF(Node aef, Node inp) @safe
{
    import std.algorithm : any, map;
    import std.array : array;

    auto inpNames = inp.sequence.map!`a["place"].get!string`.array;
    foreach(Node n; aef)
    {
        import std.regex : ctRegex, matchFirst;

        if (auto c = n["pattern"].get!string.matchFirst(ctRegex!`^~\((.+)\)$`))
        {
            import medal.exception : loadEnforce;
            import std.format : format;
            loadEnforce(inpNames.any!(n => n == c[1]),
                        format!"Invalid reference to `%s`: no such input place"(c[1]),
                        n["pattern"]);
        }
    }
}

void enforceValidCommand(string cmd, Guard g, ArcExpressionFunction aef, Node node) @safe
{
    import medal.exception : loadEnforce;

    import std.algorithm : canFind, map;
    import std.array : array;
    import std.format : format;
    import std.range : empty;
    import std.regex : ctRegex, matchAll, matchFirst;

    auto gPlaces = g.byKey.map!(k => format!"in.%s"(k.name)).array;
    auto aefPlaces = aef.byKey.array;

    loadEnforce(!cmd.empty, "`command` field should not be an empty string", node);

    foreach(m; cmd.matchAll(ctRegex!(r"~(~~)*\(([^)]+)\)", "m")))
    {
        auto pl = m[2];
        if (auto p = gPlaces.canFind(pl))
        {
            continue;
        }
        else if (aefPlaces.map!(p => format!"out.%s"(p.name)).canFind(pl))
        {
            loadEnforce(aef[Place(pl)] == SpecialPattern.File,
                        format!"Refering the output place `%s` that is not `%s`"(pl, SpecialPattern.File),
                        node);
        }
        else
        {
            import medal.exception : LoadError;
            throw new LoadError(format!"Invalid place `%s`"(pl), node);
        }
    }
    if (cmd.matchFirst(ctRegex!(r"\$\(.+\)", "m")) ||
        cmd.matchFirst(ctRegex!(r"`.+`", "m")))
    {
        import dyaml : Mark;
        import medal.logger : sharedLog;
        import std.json : JSONValue;

        Mark mark = node.startMark;
        JSONValue msg;
        msg["sender"] = "medal.loader";
        msg["message"] = "Command substitutions may hide unintended execution failures";
        msg["file"] = mark.name;
        msg["line"] = mark.line+1;
        msg["column"] = mark.column+1;
        sharedLog.warning(msg);
    }
}

///
Transition loadNetworkTransition(Node node) @safe
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
                node);
    auto con = "configuration" in node ? loadConfig(node) : Config.init;

    loadEnforce(con.tmpdir.empty, "`tmpdir` field is not valid in network transitions",
                node["configuration"]["tmpdir"]);
    loadEnforce(con.workdir.empty, "`workdir` field is not valid in network transitions",
                node["configuration"]["workdir"]);

    auto name = "name" in node ? node["name"].get!string : "";

    loadEnforce("transition" !in node,
                "Invalid field `transition`; did you mean `transitions`?",
                node);
    auto trsNode = *loadEnforce("transitions" in node,
                                "`transitions` field is needed in network transitions",
                                node);
    auto trs = trsNode.sequence
                      .map!(n => loadTransition(n))
                      .array;
    loadEnforce(!trs.empty, "at least one transition is needed in `transitions` fields",
                trsNode);

    Transition[] exitTrs, successTrs, failureTrs;

    // Note: "on" is imilicitly converted to true value :-(
    if (auto on_ = true in node)
    {
        auto on = *on_;
        exitTrs = "exit" in on ? on["exit"].sequence
                                           .map!(n => loadTransition(n))
                                           .array
                               : [];
        successTrs = "success" in on ? on["success"].sequence
                                                    .map!(n => loadTransition(n))
                                                    .array
                                     : [];
        failureTrs = "failure" in on ? on["failure"].sequence
                                                    .map!(n => loadTransition(n))
                                                    .array
                                     : [];
    }

    auto g1 = "in" in node ? loadGuard(node["in"]) : Guard.init;

    auto g2 = "out" in node ? loadGuard(node["out"]) : Guard.init;
    return new NetworkTransition(name, g1, g2, trs,
                                 exitTrs, successTrs, failureTrs, con);
}

///
Transition loadInvocationTransition(Node node) @safe
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
                node);
    auto con = "configuration" in node ? loadConfig(node) : Config.init;

    auto name = "name" in node ? node["name"].get!string : "";

    auto subFileNode = *loadEnforce("use" in node,
                                    "`use` field is needed in invocation transitions",
                                    node);
    auto subFile = buildPath(node.startMark.name.dirName, subFileNode.get!string);
    loadEnforce(subFile.exists, format!"Subnetwork file not found: `%s`"(subFile),
                subFileNode);
    auto subNode = Loader.fromFile(subFile).load;
    auto tr = loadTransition(subNode);

    auto inode = loadEnforce("in" in node, "`in` field is needed in invocation transitions", node);
    auto itpl = loadPortGuard(*inode);
    enforceInPortIsValid(itpl[1], tr.guard, *inode);

    auto onode = loadEnforce("out" in node, "`out` field is needed in invocation transitions", node);
    auto oPort = loadOutputPort(*onode);
    enforceOutPortIsValid(oPort, tr.arcExpFun, *onode);

    return new InvocationTransition(name, itpl[0], itpl[1], oPort, tr, con);
}

void enforceInPortIsValid(in Place[Place] ports, in Guard guard, Node node) @safe
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
    loadEnforce(pg.empty, format!"Ports to non-existent places: %-(%s, %)"(pg), node);

    auto gp = setDifference(guardPlaces, portPlaces);
    loadEnforce(gp.empty, format!"Missing ports to: %-(%s, %)"(gp), node);
}

void enforceOutPortIsValid(in Place[Place] ports, ArcExpressionFunction aef, Node node) @safe
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
    loadEnforce(pa.empty, format!"Ports from non-existent places: %-(%s, %)"(pa), node);
}

///
Guard loadGuard(Node node) @safe
{
    import medal.exception : loadEnforce;

    import std.algorithm : map;
    import std.array : assocArray;
    import std.exception : assumeUnique;
    import std.typecons : tuple;

    auto pats = node.sequence
                    .map!((n) {
                        auto pl = loadPlace(*loadEnforce("place" in n, "`place` field is needed", n));
                        auto pat = (*loadEnforce("pattern" in n, "`pattern` field is needed", n)).get!string;
                        return tuple(pl, InputPattern(pat));
                    })
                    .assocArray;
    return () @trusted { return pats.assumeUnique; }();
}

Tuple!(Guard, immutable Place[Place]) loadPortGuard(Node node) @trusted
{
    import medal.exception : loadEnforce;

    import std.exception : assumeUnique;
    import std.typecons : tuple;

    InputPattern[Place] guard;
    Place[Place] mapping;
    foreach(Node n; node)
    {
        auto pl = loadPlace(*loadEnforce("place" in n, "`place` field is needed", n));
        auto pat = InputPattern((*loadEnforce("pattern" in n, "`pattern` field is needed", n)).get!string);
        auto p = loadPlace(*loadEnforce("port-to" in n, "`port-to` field is needed", n));
        guard[pl] = pat;
        mapping[pl] = p;
    }
    return tuple(guard.assumeUnique, mapping.assumeUnique);
}

immutable(Place[Place]) loadOutputPort(Node node) @trusted
{
    import medal.exception : loadEnforce;

    import std.algorithm : map;
    import std.array : assocArray;
    import std.exception : assumeUnique;
    import std.typecons : tuple;

    auto port = node.sequence
                    .map!((n) {
                        auto from = loadPlace(*loadEnforce("place" in n, "`place` field is needed", n));
                        auto to = loadPlace(*loadEnforce("port-to" in n, "`port-to` field is needed", n));
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
    auto g = loadGuard(root);
    assert(g == cast(immutable)[Place("pl"): InputPattern("constant-value")]);
}

///
ArcExpressionFunction loadArcExpressionFunction(Node node) @safe
{
    import medal.exception : loadEnforce;

    import std.algorithm : map;
    import std.array : assocArray;
    import std.exception : assumeUnique;
    import std.typecons : tuple;

    auto pats = node.sequence
                    .map!((n) {
                        auto pl = loadPlace(*loadEnforce("place" in n, "`place` field is needed", n));
                        auto pat = (*loadEnforce("pattern" in n, "`pattern` field is needed", n)).get!string;
                        return tuple(pl, pat);
                    })
                    .assocArray;
    return () @trusted { return pats.assumeUnique; }();
}

///
BindingElement loadBindingElement(Node node) @safe
{
    import std.algorithm : map;
    import std.array : assocArray;
    import std.exception : assumeUnique;
    import std.typecons : tuple;

    auto tokenElems = node.mapping
                          .map!(p => tuple(loadPlace(p.key),
                                           Token(p.value.get!string)))
                          .assocArray;
    return new BindingElement(() @trusted {
        return tokenElems.assumeUnique;
    }());
}

///
Config loadConfig(Node node) @safe
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
        loadEnforce(!workdir.canFind(".."), "`..` is not allowed in `workdir`", *wdir);
    }

    string tmpdir;
    if (auto tdir = "tmpdir" in n)
    {
        import std.algorithm : startsWith;

        tmpdir = tdir.get!string;
        loadEnforce(!tmpdir.canFind(".."), "`..` is not allowed in `tmpdir`", *tdir);
        loadEnforce(tmpdir.startsWith("~(tmpdir)"), "`tmpdir` should be in the parent `tmpdir`", *tdir);
    }

    string[string] env;
    if (auto e = "env" in n)
    {
        import std.algorithm : map;
        import std.array : assocArray;
        import std.typecons : tuple;

        env = e.sequence.map!((Node nn) {
            auto name = (*loadEnforce("name" in nn, "`name` field is needed", nn)).get!string;
            auto value = (*loadEnforce("value" in nn, "`value` field is needed", nn)).get!string;
            return tuple(name, value);
        }).assocArray;
    }

    typeof(return) ret = {
        tag: tag,
        environment: () @trusted {
            import std.exception : assumeUnique;
            return env.assumeUnique;
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
    loadEnforce(idx == -1, format!"Invalid charactter `%s` was found in the place name `%s`"(pl[idx], pl), node);

    loadEnforce(pl != "." && pl != ".." && pl != "~",
                format!"Invalid place name `%s`: its name is not allowed in medal"(pl), node);

    loadEnforce(!pl.startsWith("."), format!"Invalid place name `%s`: it should not start with `.`"(pl), node);
    loadEnforce(!pl.startsWith("-"), format!"Invalid place name `%s`: it should not start with `-`"(pl), node);
    loadEnforce(!pl.endsWith("&"), format!"Invalid place name `%s`: it should not end with `&`"(pl), node);

    return Place(pl);
}
