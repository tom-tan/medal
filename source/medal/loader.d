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
    import std.exception : enforce;

    auto type = (*enforce("type" in node)).as!string;
    switch(type)
    {
    case "shell":
        return loadShellCommandTransition(node);
    case "network":
        return loadNetworkTransition(node, file);
    case "invocation":
        return loadInvocationTransition(node, file);
    default:
        assert(false, "Unknown type: "~type);
    }
}

///
unittest
{
    import dyaml : Loader;
    import medal.message : TransitionSucceeded;
    import medal.transition.shell : ShellCommandTransition;
    import std.concurrency : receiveTimeout, thisTid;
    import std.datetime : seconds;
    import std.variant : Variant;

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
    spawnFire(tr, new BindingElement, thisTid);
    auto received = receiveTimeout(10.seconds,
        (TransitionSucceeded ts) {
            assert(ts.tokenElements == [Place("ret"): new Token("0")]);
        },
        (Variant _) { assert(false); },
    );
    assert(received);
}

///
Transition loadShellCommandTransition(Node node) @safe
in("type" in node)
in(node["type"].as!string == "shell")
do
{
    import medal.transition.shell : ShellCommandTransition;
    import std.exception : enforce;
    import std.range :empty;

    auto name = "name" in node ? node["name"].get!string : "";
    auto command = (*enforce("command" in node)).as!string;
    enforce(!command.empty);
    auto g = "in" in node ? loadGuard(node["in"]) : Guard.init;

    auto aef = "out" in node ? loadArcExpressionFunction(node["out"])
                             : ArcExpressionFunction.init;
    return new ShellCommandTransition(name, command, g, aef);
}

///
Transition loadNetworkTransition(Node node, string file) @safe
in("type" in node)
in(node["type"].as!string == "network")
do
{
    import medal.transition.network : NetworkTransition;
    import std.algorithm : map;
    import std.array : array;
    import std.exception : enforce;
    import std.range : empty;

    enforce("configurations" !in node, "Invalid field `configurations`; did you mean `configuration`?");
    auto con = "configuration" in node ? loadConfig(node) : Config.init;
    enforce(con.tmpdir.empty);
    enforce(con.workdir.empty);

    auto name = "name" in node ? node["name"].get!string : "";
    auto trs = (*enforce("transitions" in node))
                    .sequence
                    .map!(n => loadTransition(n, file))
                    .array;
    enforce(!trs.empty);

    auto g1 = "in" in node ? loadGuard(node["in"]) : Guard.init;

    auto g2 = "out" in node ? loadGuard(node["out"]) : Guard.init;
    return new NetworkTransition(name, g1, g2, trs, con);
}

Transition loadInvocationTransition(Node node, string file) @safe
in("type" in node)
in(node["type"].as!string == "invocation")
do
{
    import dyaml : Loader;

    import medal.transition.network : InvocationTransition;

    import std.algorithm : map;
    import std.array : array;
    import std.exception : enforce;
    import std.file : exists;
    import std.path : buildPath, dirName;
    import std.range : empty;

    auto con = "configuration" in node ? loadConfig(node) : Config.init;

    auto name = "name" in node ? node["name"].get!string : "";

    auto subFile = (*enforce("use" in node)).get!string;
    subFile = buildPath(file.dirName, subFile);
    enforce(subFile.exists, "Subnetwork file not found:"~subFile);
    auto subNode = Loader.fromFile(subFile).load;
    auto tr = loadTransition(subNode, subFile);

    enforce("in" in node);
    auto itpl = loadPortGuard(node["in"]);

    enforce("out" in node);
    auto oPort = loadOutputPort(node["out"]);

    return new InvocationTransition(name, itpl[0], itpl[1], oPort, tr, con);
}

///
Guard loadGuard(Node node) @safe
{
    import std.algorithm : map;
    import std.array : assocArray;
    import std.exception : assumeUnique, enforce;
    import std.typecons : tuple;

    auto pats = node.sequence
                    .map!((n) {
                        auto pl = (*enforce("place" in n)).as!string;
                        auto pat = (*enforce("pattern" in n)).as!string;
                        return tuple(Place(pl), InputPattern(pat));
                    })
                    .assocArray;
    return () @trusted { return pats.assumeUnique; }();
}

Tuple!(Guard, immutable Place[Place]) loadPortGuard(Node node) @trusted
{
    import std.exception : assumeUnique, enforce;
    import std.typecons : tuple;

    InputPattern[Place] guard;
    Place[Place] mapping;
    foreach(Node n; node)
    {
        auto pl = Place((*enforce("place" in n)).as!string);
        auto pat = InputPattern((*enforce("pattern" in n)).as!string);
        auto p = Place((*enforce("port-to" in n)).as!string);
        guard[pl] = pat;
        mapping[pl] = p;
    }
    return tuple(guard.assumeUnique, mapping.assumeUnique);
}

immutable(Place[Place]) loadOutputPort(Node node) @trusted
{
    import std.algorithm : map;
    import std.array : assocArray;
    import std.exception : assumeUnique, enforce;
    import std.typecons : tuple;

    auto port = node.sequence
                    .map!((n) {
                        auto from = Place((*enforce("place" in n)).as!string);
                        auto to = Place((*enforce("port-to" in n)).as!string);
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
    import std.algorithm : map;
    import std.array : assocArray;
    import std.exception : assumeUnique, enforce;
    import std.typecons : tuple;

    auto pats = node.sequence
                    .map!((n) {
                        auto pl = (*enforce("place" in n)).as!string;
                        auto pat = (*enforce("pattern" in n)).as!string;
                        return tuple(Place(pl), OutputPattern(pat));
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
                          .map!(p => tuple(Place(p.key.as!string),
                                           new Token(p.value.as!string)))
                          .assocArray;
    return new BindingElement(() @trusted { 
        return tokenElems.assumeUnique; 
    }());
}

///
Config loadConfig(Node node) @safe
in("configuration" in node)
{
    import std.algorithm : canFind;
    import std.exception : assumeUnique, enforce;

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
        enforce(!workdir.canFind(".."), "`..` is not allowed in `workdir`");
    }

    string tmpdir;
    if (auto tdir = "tmpdir" in n)
    {
        import std.algorithm : startsWith;

        tmpdir = tdir.get!string;
        enforce(!tmpdir.canFind(".."), "`..` is not allowed in `tmpdir`");
        enforce(tmpdir.startsWith("~(tmpdir)"), "`tmpdir` should be in the parent `tmpdir`");
    }

    string[string] environment;
    enforce("environment" !in n, "Invalid field `environment`; did you mean `environments`?");
    if (auto env = "environments" in n)
    {
        import std.algorithm : map;
        import std.array : assocArray;
        import std.typecons : tuple;

        environment = env.sequence.map!((Node nn) {
            return tuple((*enforce("name" in nn)).get!string,
                         (*enforce("value" in nn)).get!string);
        }).assocArray;
    }

    typeof(return) ret = { 
        tag: tag, 
        environment: () @trusted {
            return environment.assumeUnique;
        }(),
        workdir: workdir,
        tmpdir: tmpdir,
    };
    return ret;
}
