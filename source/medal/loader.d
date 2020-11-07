/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.loader;

import dyaml : Node;

import medal.config : Config;
import medal.transition.core;

///
Transition loadTransition(Node node) @safe
{
    import std.exception : enforce;

    auto type = (*enforce("type" in node)).as!string;
    switch(type)
    {
    case "shell":
        return loadShellCommandTransition(node);
    case "network":
        return loadInvocationTransition(node);
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
    auto tr = loadTransition(trRoot);
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
Transition loadInvocationTransition(Node node) @safe
in("type" in node)
in(node["type"].as!string == "network")
do
{
    import medal.transition.network : InvocationTransition;
    import std.algorithm : map;
    import std.array : array;
    import std.exception : enforce;
    import std.range : empty;

    auto con = "configuration" in node ? loadConfig(node) : Config.init;

    auto name = "name" in node ? node["name"].get!string : "";
    auto trs = (*enforce("transitions" in node))
                    .sequence
                    .map!loadTransition
                    .array;
    enforce(!trs.empty);

    auto g1 = "in" in node ? loadGuard(node["in"]) : Guard.init;

    auto g2 = "out" in node ? loadGuard(node["out"]) : Guard.init;
    return new InvocationTransition(name, g1, g2, trs, con);
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
    import std.exception : assumeUnique;

    auto n = node["configuration"];
    string tag;
    if (auto t = "tag" in n)
    {
        tag = t.get!string;
    }

    string[string] environment;
    if (auto env = "environments" in n)
    {
        import std.algorithm : map;
        import std.array : assocArray;
        import std.exception : enforce;
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
    };
    return ret;
}
