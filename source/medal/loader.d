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

    auto typeNode = node.edig("type");
    switch(typeNode.get!string)
    {
    case "shell":
        return loadShellCommandTransition(node);
    case "network":
        return loadNetworkTransition(node);
    case "invocation":
        return loadInvocationTransition(node);
    default:
        import std.format : format;
        throw new LoadError(format!"Unknown type: `%s`"(typeNode.get!string), typeNode);
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
    import std.algorithm : map;
    import std.array : array;
    import std.range : empty;

    auto name = node.dig("name", "").get!string;

    auto g = loadGuard(node.dig("in", []));

    auto aef = loadArcExpressionFunction(node.dig("out", []));

    enforceValidShellAEF(node.dig("out", []), node.dig("in", []));

    auto cmdNode = node.edig("command");
    auto command = cmdNode.get!string;
    auto acceptedParams = node.inPlaceNames.map!"`in.`~a".array ~
                          node.newFilePlaceNames.map!"`out.`~a".array ~
                          configParameters;
    enforceValidCommand(command, acceptedParams, cmdNode);

    auto logEntries = loadUserLogEntries(node);

    return new ShellCommandTransition(name, command, g, aef,
                                      logEntries["pre"],
                                      logEntries["success"],
                                      logEntries["failure"]);
}

void enforceValidShellAEF(Node aef, Node inp) @safe
{
    import std.algorithm : canFind, map;
    import std.array : array;

    auto inpNames = inp.sequence.map!`a["place"].get!string`.array;
    foreach(Node n; aef)
    {
        import std.regex : ctRegex, matchFirst;

        if (auto c = n["pattern"].get!string.matchFirst(ctRegex!`^~\((.+)\)$`))
        {
            import medal.exception : loadEnforce;
            import std.array : join, split;
            import std.format : format;
            auto r = c[1];
            auto pats = r.split(".");
            switch(pats[0])
            {
            case "in":
                auto place = pats[1..$].join(".");
                loadEnforce(inpNames.canFind(place),
                            format!"Invalid reference to `%s`: no such input places"(r),
                            n["pattern"]);
                break;
            case "tr":
                loadEnforce(r == SpecialPattern.Stdout[2..$-1] ||
                            r == SpecialPattern.Stderr[2..$-1] ||
                            r == SpecialPattern.Return[2..$-1],
                            format!"Invalid reference to `%s`"(r),
                            n["pattern"]);
                break;
            case SpecialPattern.File[2..$-1]:
                break;
            default:
                loadEnforce(false, format!"Invalid reference to `%s`"(r), n["pattern"]);
                break;
            }
        }
    }
}

void enforceValidCommand(string cmd, string[] acceptedParams, Node node) @safe
{
    import medal.exception : loadEnforce;

    import std.algorithm : canFind;
    import std.format : format;
    import std.range : empty;
    import std.regex : ctRegex, matchAll, matchFirst;

    loadEnforce(!cmd.empty, "`command` field should not be an empty string", node);

    foreach(m; cmd.matchAll(ctRegex!(r"~(~~)*\(([^)]+)\)", "m")))
    {
        auto pl = m[2];
        if (auto p = acceptedParams.canFind(pl))
        {
            continue;
        }
        else
        {
            import medal.exception : LoadError;
            throw new LoadError(format!"Invalid reference `%s`"(pl), node);
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
    auto con = "configuration" in node ? loadConfig(node) : Config.init; // TODO

    loadEnforce(con.tmpdir.empty, "`tmpdir` field is not valid in network transitions",
                node["configuration"]["tmpdir"]);
    loadEnforce(con.workdir.empty, "`workdir` field is not valid in network transitions",
                node["configuration"]["workdir"]);

    auto name = node.dig("name", "").get!string;

    loadEnforce("transition" !in node,
                "Invalid field `transition`; did you mean `transitions`?",
                node);
    auto trsNode = node.edig("transitions");
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
        exitTrs = on.dig("exit", [])
                    .sequence
                    .map!(n => loadTransition(n))
                    .array;
        successTrs = on.dig("success", [])
                       .sequence
                       .map!(n => loadTransition(n))
                       .array;
        failureTrs = on.dig("failure", [])
                       .sequence
                       .map!(n => loadTransition(n))
                       .array;
    }

    auto g1 = loadGuard(node.dig("in", []));

    auto g2 = loadGuard(node.dig("out", []));

    auto logEntries = loadUserLogEntries(node);

    return new NetworkTransition(name, g1, g2, trs,
                                 exitTrs, successTrs, failureTrs, con,
                                 logEntries["pre"],
                                 logEntries["success"],
                                 logEntries["failure"]);
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

    auto name = node.dig("name", "").get!string;

    auto subFileNode = node.edig("use");
    auto subFile = buildPath(node.startMark.name.dirName, subFileNode.get!string);
    loadEnforce(subFile.exists, format!"Subnetwork file not found: `%s`"(subFile),
                subFileNode);
    auto subNode = Loader.fromFile(subFile).load;
    auto tr = loadTransition(subNode);

    auto inode = node.edig("in");
    auto itpl = loadPortGuard(inode);
    enforceInPortIsValid(itpl[1], tr.guard, inode);

    auto onode = node.edig("out");
    auto aef = loadArcExpressionFunction(onode);

    enforceValidInvocationAEF(onode, inode, tr);

    auto logEntries = loadUserLogEntries(node);

    return new InvocationTransition(name, itpl[0], aef, itpl[1], tr, con,
                                    logEntries["pre"],
                                    logEntries["success"],
                                    logEntries["failure"]);
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

void enforceValidInvocationAEF(Node aef, Node inp, Transition tr) @safe
{
    import std.algorithm : canFind, map;
    import std.array : array;

    auto inpNames = inp.sequence.map!`a["place"].get!string`.array;
    foreach(Node n; aef)
    {
        import std.regex : ctRegex, matchFirst;

        if (auto c = n["pattern"].get!string.matchFirst(ctRegex!`^~\((.+)\)$`))
        {
            import medal.exception : loadEnforce;
            import std.array : join, split;
            import std.format : format;
            auto r = c[1];
            auto pats = r.split(".");
            switch(pats[0])
            {
            case "in":
                auto place = pats[1..$].join(".");
                loadEnforce(inpNames.canFind(place),
                            format!"Invalid reference to `%s`: no such input places"(r),
                            n["pattern"]);
                break;
            case "tr":
                auto place = pats[1..$].join(".");
                auto outNames = tr.arcExpFun.byKey.map!"a.name";
                loadEnforce(outNames.canFind(place),
                            format!"Invalid reference to `%s`"(r),
                            n["pattern"]);
                break;
            case SpecialPattern.File[2..$-1]:
                loadEnforce(false,
                            format!"Invalid reference to `%s`: not supported by invocation transitions"(r),
                            n["pattern"]);
                break;
            default:
                loadEnforce(false, format!"Invalid reference to `%s`"(r), n["pattern"]);
                break;
            }
        }
    }
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
                        auto pl = loadPlace(n.edig("place"));
                        auto pat = n.edig("pattern").get!string;
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
        auto pl = loadPlace(n.edig("place"));
        auto pat = InputPattern(n.edig("pattern").get!string);
        auto p = loadPlace(n.edig("port-to"));
        guard[pl] = pat;
        mapping[pl] = p;
    }
    return tuple(guard.assumeUnique, mapping.assumeUnique);
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
                        auto pl = loadPlace(n.edig("place"));
                        auto pat = n.edig("pattern").get!string;
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

    import std.algorithm : canFind, startsWith;
    import std.range : empty;

    auto n = node["configuration"];
    auto tag = n.dig("tag", "").get!string;

    auto workdir = n.dig("workdir", "").get!string;
    loadEnforce(!workdir.canFind(".."), "`..` is not allowed in `workdir`", n);

    auto tmpdir = n.dig("tmpdir", "").get!string;
    loadEnforce(!tmpdir.canFind(".."), "`..` is not allowed in `tmpdir`", n);
    loadEnforce(tmpdir.empty || tmpdir.startsWith("~(tmpdir)"), "`tmpdir` should be in the parent `tmpdir`", n);

    string[string] env;
    if (auto e = "env" in n)
    {
        import std.algorithm : map;
        import std.array : assocArray;
        import std.typecons : tuple;

        env = e.sequence.map!((Node nn) {
            auto name = nn.edig("name").get!string;
            auto value = nn.edig("value").get!string;
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

auto loadUserLogEntries(Node node)
{
    import std.algorithm : map;
    import std.array : array;

    auto userLogEntries = [
        "pre": "",
        "success": "",
        "failure": "",
    ];
    if ("log" !in node)
    {
        return userLogEntries;
    }
    auto userLogs = node["log"];
    if (auto pre = "pre" in userLogs)
    {
        userLogEntries["pre"] = (*pre).get!string;
        auto acceptedParams = node.inPlaceNames.map!"`in.`~a".array ~
                              configParameters;
        enforceValidCommand(userLogEntries["pre"], acceptedParams, *pre);
    }
    if (auto success = "success" in userLogs)
    {
        userLogEntries["success"] = (*success).get!string;
        auto acceptedParams = node.inPlaceNames.map!"`in.`~a".array ~
                              node.outPlaceNames.map!"`out.`~a".array ~
                              node.portPlaceNames.map!"`tr.`~a".array ~
                              configParameters;
        enforceValidCommand(userLogEntries["success"], acceptedParams, *success);
    }
    if (auto failure = "failure" in userLogs)
    {
        userLogEntries["failure"] = (*failure).get!string;
        auto acceptedParams = node.inPlaceNames.map!"`in.`~a".array ~
                              node.portPlaceNames.map!"`tr.`~a".array ~
                              configParameters ~
                              "interrupted";
        enforceValidCommand(userLogEntries["failure"], acceptedParams, *failure);
    }
    return userLogEntries;
}

auto inPlaceNames(Node node)
{
    import std.algorithm : map;
    import std.array : array;

    return node.dig("in", [])
               .sequence
               .map!(n => n.edig("place").get!string)
               .array;
}

auto configParameters()
{
    return ["tag", "tmpdir", "workdir"];
}

auto portPlaceNames(Node node)
{
    import medal.exception : loadEnforce, LoadError;
    import std.format : format;

    auto typeNode = node.edig("type");
    switch(typeNode.get!string)
    {
    case "shell":
        return ["stdout", "stderr", "return"];
    case "network":
        return (string[]).init;
    case "invocation":
        import dyaml : Loader;

        import std.file : exists;
        import std.path : buildPath, dirName;

        auto subFileNode = node.edig("use");
        auto subFile = buildPath(node.startMark.name.dirName, subFileNode.get!string);
        loadEnforce(subFile.exists, format!"Subnetwork file not found: `%s`"(subFile),
                    subFileNode);
        auto subNode = Loader.fromFile(subFile).load;
        return subNode.outPlaceNames;
    default:
        throw new LoadError(format!"Unsupported transition type: %s"(typeNode.get!string),
                            typeNode);
    }
}

auto outPlaceNames(Node node)
{
    import std.algorithm : map;
    import std.array : array;

    return node.dig("out", [])
               .sequence
               .map!(n => n.edig("place").get!string)
               .array;
}

auto newFilePlaceNames(Node node)
{
    import std.algorithm : filter, map;
    import std.array : array;

    return node.dig("out", [])
               .sequence
               .filter!(n => n.edig("pattern") == "~(newfile)")
               .map!(n => n.edig("place").get!string)
               .array;
}

auto dig(T)(Node node, string key, T default_)
{
    return dig(node, [key], default_);
}

auto dig(T)(Node node, string[] keys, T default_)
{
    Node ret = node;
    foreach(k_; keys)
    {
        auto k = k_ == "true" ? "on" : k_;
        if (auto n = k in ret)
        {
            ret = *n;
        }
        else
        {
            static if (is(T : void[]))
            {
                return Node((Node[]).init);
            }
            else
            {
                return Node(default_);
            }
        }
    }
    return ret;
}

/// enforceDig
auto edig(Node node, string key, string msg = "")
{
    return edig(node, [key], msg);
}

/// ditto
auto edig(Node node, string[] keys, string msg = "")
{
    Node ret = node;
    foreach(k_; keys)
    {
        auto k = k_ == "true" ? "on" : k_;
        if (auto n = k in ret)
        {
            ret = *n;
        }
        else
        {
            import medal.exception : LoadError;

            import std.format : format;
            import std.range : empty;

            msg = msg.empty ? format!"No such field: %s"(k_) : msg;
            throw new LoadError(msg, ret);
        }
    }
    return ret;
}
