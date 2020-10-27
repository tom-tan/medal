module medal.engine;

import medal.transition;

import std;

///
struct EngineWillStop
{
    BindingElement bindingElement;
}

///
alias EngineStopTransition = immutable EngineStopTransition_;
///
immutable class EngineStopTransition_: Transition
{
    ///
    this(in Guard g) pure
    {
        super(g, null);
    }

    override void fire(in BindingElement be, Tid networkTid) const
    {
        send(networkTid, EngineWillStop(be));
    }
}

///
struct Engine
{
    ///
    this(in Transition[] trs)
    in(!trs.empty)
    do
    {
        transitions = trs;
        store = Store(trs);
        rule = Rule(trs);
    }

    ///
    BindingElement run(in BindingElement initBe)
    {
        auto running = true;
        Rebindable!(typeof(return)) ret;
        send(thisTid, initBe);
        while(running)
        {
            receive(
                (in BindingElement be) {
                    store.put(be);
                    foreach(tr; rule.transitions)
                    {
                        if (auto nextBe = tr.fireable(store))
                        {
                            store.remove(nextBe);
                            spawn((in Transition t, in BindingElement be) => t.fire(be, ownerTid),
                                  tr, nextBe);
                        }
                    }
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
                (Variant v) {
                    running = false;
                },
            );
        }
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
    this(in Transition[] trs) pure
    in(!trs.empty)
    do
    {
        foreach(t; trs)
        {
            chain(t.guard.byKey,
                  t.arcExpFun.byKey).filter!(p => p !in state)
                                    .each!(p => state[p] = []);
        }
    }

    ///
    void put(in BindingElement be) pure
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
        foreach(p, t; be.tokenElements)
        {
            auto split = state[p].findSplit([t]);
            state[p] = split[0] ~ split[2];
        }
    }

    // `dispatch(BindingElement) const pure` needs much duplication cost...

    string toString() const pure
    {
        return state.to!string;
    }
    const(Token)[][Place] state;
}

///
struct Rule
{
    this(in Transition[] trs) pure
    {
        transitions = trs;
    }

    /+
    auto dispatch(Store store, BindingElement trigger) const pure
    {
        return transitions.map!(t => t.fireable(store))
                          .filter!(tuple => !tuple.isNull)
                          .map!(tuple => tuple.get)
                          .array;
        // return tuple(Transition, BindingElement)[]
    }+/

    Transition[] transitions;
}
