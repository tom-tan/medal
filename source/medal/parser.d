module medal.parser;

import dyaml;
import sumtype;

import medal.types;
import medal.flux;

@safe:

///
auto parse(Node root) pure
{
    import std.exception: assumeUnique, enforce;
    import std.typecons: tuple;
    enforce("store" in root &&
            "transitions" in root,
            "`store` and `transitions` fields are needed");

    immutable namespace =
        root.fetch("configuration", Node(string[].init, string[].init))
            .fetch("namespace", Node(""))
            .as!string;

    // store and initial state
    VariableType[Variable] vars;
    Payload initPayload;
    foreach(Node n; root["store"])
    {
        import std.format: format;
        enforce("variable" in n && "type" in n, 
                "`variable` and `type` fields are needed in `store` field");

        immutable t = n["type"].as!string;
        immutable v = Variable(namespace, n["variable"].as!string);
        switch(t)
        {
        case "int":
            vars[v] = MedalType!Int.init;
            break;
        case "string":
            vars[v] = MedalType!Str.init;
            break;
        default:
            throw new Exception(format!"Invalid type for %s: %s"(v, t));
        }

        if (auto default_ = "default" in n)
        {
            immutable str = default_.as!string;
            auto val = vars[v].match!(_ => _.fromString(str));
            enforce(!val.isNull, format!"Invalid initial value for %s: %s"(v, str));
            () @trusted { initPayload[v] = val.get; }(); // due to ValueType#opAsign
        }
    }
    vars[Variable(namespace, "exit")]= MedalType!Int.init;
    auto payload = () @trusted { return initPayload.assumeUnique; }();
    auto initEvent = new ReduceAction(namespace, payload);

    EventRule[] rules;
    Task[][ActionType] saga;
    foreach(Node n; root["transitions"])
    {
        import std.concurrency: Generator, yield;
        import std.algorithm: map;
        import std.array: assocArray, array;
        enforce("type" in n && "pattern" in n && "tasks" in n,
                "`type`, `pattern` and `tasks` fields are needed in `transitions` field");
        auto type = n["type"].as!string;
        auto r = () @trusted {
            import std.range: tee;
            return n["pattern"].generator
                               .map!(n => parsePattern(n, vars, namespace))
                               .tee!((pattern) {
                                   auto type = pattern[1].type;
                                   auto pat = pattern[1].pattern;
                                   enforce(type.match!(_ => _.isValidInputPattern(pat)),
                                           "Invalid input pattern: "~pat);
                               })
                               .assocArray;
        }();
        auto r1 = () @trusted { return r.assumeUnique; }();
        rules ~= EventRule(namespace, type, r1);

        auto tasks = () @trusted { // @suppress(dscanner.suspicious.unmodified)
            return n["tasks"].generator
                             .map!(t => parseTask(t, vars, namespace))
                             .array;
        }();
        saga[type] = tasks;
    }
    rules ~= EventRule("medal", "exit",
                       [
                           Variable(namespace, "exit"): Pattern(ExitType, SpecialPatterns.Any)
                       ]);
    saga["exit"] = [Task("medal", "", [MedalExit: Pattern(ExitType, "0")])]; // should be propagated
    auto vs = () @trusted { return vars.assumeUnique; }();
    auto ss = () @trusted { return saga.assumeUnique; }();
    return tuple!(ReduceAction, "initEvent", Store, "store", EventRule[], "rules")(initEvent, new Store(vs, ss), rules); // @suppress(dscanner.style.long_line)
}

///
auto generator(Node oprange) @trusted
{
    import std.concurrency: Generator, yield;
    return new Generator!Node({
        foreach(Node e; oprange) { yield(e); }
    });
}

///
auto parsePattern(Node pat, VariableType[Variable] vars, string ns)
{
    import std.exception: enforce;
    enforce("variable" in pat && "value" in pat);
    const v = Variable(ns, pat["variable"].as!string);
    if (auto type = v in vars)
    {
        import std.typecons: tuple;
        return tuple(v, Pattern(*type, pat["value"].as!string));
    }
    else
    {
        import std.format: format;
        throw new Exception(format!"Variable `%s` is not declared in `store` field"(v));
    }
}

///
auto parseTask(Node task, VariableType[Variable] vars, string ns) @trusted
{
    import std.algorithm: map;
    import std.array: assocArray;
    import std.exception: enforce, assumeUnique;

    auto command = task.fetch("call", Node("")).as!string;
    auto vs = task["out"].generator.map!((n) {
        auto pat = parsePattern(n, vars, ns);
        enforce(pat[1].pattern != SpecialPatterns.Any, "Invalid output pattern: `_`");
        return pat;
    }).assocArray;

    return Task(ns, command, vs.assumeUnique);
}

///
auto fetch(Node node, string key, Node default_) pure
{
    if (auto ret = key in node)
    {
        return *ret;
    }
    else
    {
        return default_;
    }
}

unittest
{
    Node root = Loader.fromFile("examples/simple.yml").load;
    parse(root);
}

unittest
{
    Node root = Loader.fromFile("examples/simple-str.yml").load;
    parse(root);
}
