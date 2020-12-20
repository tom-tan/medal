/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.engine;

import medal.config : Config;
import medal.logger;
import medal.message;
import medal.transition.core;

import std.algorithm : all, canFind;
import std.concurrency : Tid;
import std.json : JSONValue;
import std.range : byPair, empty;

///
struct EngineWillStop
{
    BindingElement bindingElement;
}

///
immutable class EngineStopTransition_: Transition
{
    ///
    this(in Guard g) @nogc nothrow pure @safe
    {
        super("engine-stop", g, ArcExpressionFunction.init);
    }

    ///
    override void fire(in BindingElement be, Tid networkTid, Config config = Config.init, Logger logger = null) const
    {
        import std.concurrency : send;

        scope(success) logger.trace(oneShotMsg(be, config));
        scope(failure) logger.critical(failureMsg(be, config, "unknown error"));
        send(networkTid, EngineWillStop(be));
    }

    static JSONValue oneShotMsg(in BindingElement be, in Config con) pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "oneshot";
        ret["transition-type"] = "engine-stop";
        ret["tag"] = con.tag;
        ret["result"] = be.tokenElements.to!(string[string]);
        return ret;
    }

    static JSONValue failureMsg(in BindingElement be, in Config con, in string cause) pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "oneshot-failure";
        ret["transition-type"] = "engine-stop";
        ret["tag"] = con.tag;
        ret["result"] = be.tokenElements.to!(string[string]);
        ret["cause"] = cause;
        return ret;
    }
}

/// ditto
alias EngineStopTransition = immutable EngineStopTransition_;

///
struct Engine
{
    ///
    this(in Transition tr) nothrow pure @trusted
    {
        import std.algorithm : map;
        import std.array : assocArray;
        import std.exception : assumeUnique;
        import std.typecons : tuple;

        auto g = tr.arcExpFun
                   .byKey
                   .map!(p => tuple(p, InputPattern(SpecialPattern.Any)))
                   .assocArray;
        this([tr], g.assumeUnique);
    }

    ///
    this(in Transition[] trs, in Guard stopGuard = Guard.init) nothrow pure @safe
    in(!trs.empty)
    do
    {
        transitions = trs;
        if (!stopGuard.empty)
        {
            transitions ~= new EngineStopTransition(stopGuard);
        }
        store = Store(transitions);
        rule = Rule(transitions);
    }

    ///
    BindingElement run(in BindingElement initBe, Config config = Config.init, Logger logger = sharedLog)
    {
        import std.concurrency : LinkTerminated, receive, send, thisTid;
        import std.container.rbtree : redBlackTree;
        import std.conv : to;
        import std.typecons : Rebindable;
        import std.variant : Variant;

        logger.trace(startMsg(initBe, config));
        scope(failure) logger.critical(failureMsg(initBe, config, "Unknown error"));

        if (!config.reuseParentTmpdir && !config.tmpdir.empty)
        {
            import std.file : exists, mkdirRecurse;
            if (config.tmpdir.exists)
            {
                logger.critical(failureMsg(initBe, config, "tmpdir already exists: "~config.tmpdir));
                return typeof(return).init;
            }
            // it will be deleted by root (app.main)
            mkdirRecurse(config.tmpdir);
        }

        auto running = true;
        auto trTids = redBlackTree!(((in Tid a, in Tid b) => a.to!string < b.to!string), Tid);
        Rebindable!(typeof(return)) ret;
        send(thisTid, TransitionSucceeded(initBe));
        while (running)
        {
            receive(
                (TransitionSucceeded ts) {
                    logger.trace(recvMsg(ts, config));
                    store.put(ts.tokenElements);
                    auto candidates = rule.dispatch(ts.tokenElements);
                    while (!candidates.empty)
                    {
                        import std.range : front, popFront;

                        auto c = candidates.front;
                        if (auto be = c.fireable(store))
                        {
                            store.remove(be);
                            auto tid = spawnFire(c, be, thisTid, config, logger);
                            trTids.insert(tid);
                            logger.trace(fireMsg(c, be, tid, config));
                            continue;
                        }
                        candidates.popFront;
                    }
                },
                (TransitionFailed tf) {
                    logger.trace(recvMsg(tf, config));
                    running = false;
                },
                (in SignalSent sig) {
                    // send sig to all transitions
                    running = false;
                },
                (in EngineWillStop ews) {
                    // send sig? to all transitions
                    ret = ews.bindingElement;
                    running = false;
                },
                (LinkTerminated lt) {
                    trTids.removeKey(lt.tid);
                },
                (Variant v) {
                    running = false;
                },
            );
        }
        while (!trTids.empty)
        {
            import std.concurrency : receiveOnly;
            auto recv = receiveOnly!LinkTerminated;
            trTids.removeKey(recv.tid);
        }
        logger.trace(successMsg(ret, config));
        return ret;
    }

    JSONValue recvMsg(in TransitionSucceeded ts, in Config con) @trusted
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "engine";
        ret["event"] = "recv";
        ret["tag"] = con.tag;
        ret["elems"] = ts.tokenElements.tokenElements.to!(string[string]);
        ret["success"] = true;
        ret["thread-id"] = (cast()ts.tid).to!string[4..$-1];
        return ret;
    }

    JSONValue recvMsg(in TransitionFailed tf, in Config con) @trusted
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "engine";
        ret["event"] = "recv";
        ret["tag"] = con.tag;
        ret["elems"] = tf.tokenElements.tokenElements.to!(string[string]);
        ret["success"] = false;
        ret["thread-id"] = (cast()tf.tid).to!string[4..$-1];
        ret["cause"] = tf.cause;
        return ret;
    }

    JSONValue startMsg(in BindingElement be, in Config con) pure @trusted
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "engine";
        ret["event"] = "start";
        ret["tag"] = con.tag;
        ret["in"] = be.tokenElements.to!(string[string]);
        return ret;
    }

    JSONValue successMsg(in BindingElement be, in Config con) pure @trusted
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "engine";
        ret["event"] = "end";
        ret["tag"] = con.tag;
        ret["out"] = be is null ? (string[string]).init : be.tokenElements.to!(string[string]);
        ret["success"] = true;
        return ret;
    }

    JSONValue failureMsg(in BindingElement be, in Config con, in string cause = "") pure @trusted
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "engine";
        ret["event"] = "end";
        ret["tag"] = con.tag;
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["success"] = false;
        ret["cause"] = cause;
        return ret;
    }

    JSONValue fireMsg(in Transition tr, in BindingElement be, in Tid tid, in Config con) @trusted
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "engine";
        ret["event"] = "fire";
        ret["tag"] = con.tag;
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["transition"] = tr.name;
        ret["thread-id"] = (cast()tid).to!string[4..$-1];
        return ret;
    }

    Transition[] transitions;
    Store store;
    Rule rule;
}

///
struct Store
{
    ///
    this(in Transition[] trs) nothrow pure @safe
    in(!trs.empty)
    do
    {
        import std.algorithm : each, filter;
        import std.range : chain;

        foreach(t; trs)
        {
            chain(t.guard.byKey,
                  t.arcExpFun.byKey).filter!(p => p !in state)
                                    .each!(p => state[p] = []);
        }
    }

    ///
    void put(in BindingElement be) pure @safe
    in(be.tokenElements.byPair.all!(pt => pt[0] in state))
    do
    {
        foreach(p, t; be.tokenElements)
        {
            state[p] = state[p] ~ t;
        }
    }

    ///
    void remove(in BindingElement be)
    in(be.tokenElements.byPair.all!(pt => pt[0] in state))
    in(be.tokenElements.byPair.all!(pt => state[pt[0]].canFind(pt[1])))
    do
    {
        import std.algorithm : findSplit;

        foreach(p, t; be.tokenElements)
        {
            auto split = state[p].findSplit([t]);
            state[p] = split[0] ~ split[2];
        }
    }

    string toString() const pure @safe
    {
        import std.conv : to;
        return state.to!string;
    }
    const(Token)[][Place] state;
}

///
@safe struct Rule
{
    ///
    this(in Transition[] trs) @nogc nothrow pure
    {
        transitions = trs;
    }

    ///
    auto dispatch(BindingElement trigger) const
    {
        return transitions[];
    }

    Transition[] transitions;
}
