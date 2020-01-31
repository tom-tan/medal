module medal.flux;
import sumtype;

alias Event = ReduceAction;

/// Assignments -> ActionType
alias RuleType = UserAction;
///
class EventRules
{
    ///
    auto dispatch(in Event e)
    {
        import std.algorithm: filter;
        return rules.filter!(r => e.match(r));
    }

    ///
    RuleType[] rules;
}

///
auto match(in Event e, RuleType r)
{
    import std.range: front, empty;
    import std.algorithm: all;
    foreach(pat; r.payload)
    {
        if (!e.match(pat))
        {
            return false;
        }
    }
    return true;
    //return r.payload.all!(pat => e.match(pat));
}

///
auto match(in Event e, Assignment pat)
{
    import std.algorithm: find;
    import std.range: front, empty;
    const m = e.payload.find!(p => p.variable == pat.variable);
    if (m.empty)
    {
        return false;
    }
    else
    {
        auto as = m.front;
        return as == pat; // does not match `_`
    }
}

///
class Store
{
    ///
    ValueType[const(Variable)] state;
    //Assignment[] state;

    ///
    Task[ActionType] rootSaga;

    ///
    auto reduce(in ReduceAction action)
    {
        import std.algorithm: each;
        action.payload.each!((in Assignment as) {
            state[as.variable] = as.value;
        });
        return this;
    }

    ///
    auto dispatch(UserAction a)
    {
        auto c = rootSaga[a.type];
        return fork(c, a);
    }
}

alias ActionType = string;
alias Payload = Assignment[];
alias Meta = Assignment[];

///
class Action
{
    ///
    this(string ns, ActionType t, Payload p)
    {
        namespace = ns;
        type = t;
        payload = p;
    }

    ///
    string namespace;
    ///
    ActionType type;
    ///
    Payload payload;
}

alias UserAction = Action;
alias ReduceAction = Action;

///
struct Int
{
    ///
    int n;
}

alias ValueType = SumType!(Int);

///
struct Variable
{
    ///
    this(string ns, string n)
    {
        namespace = ns;
        name = n;
    }

    ///
    string namespace;
    ///
    string name;
}

///
struct Assignment
{
    ///
    static opCall(Variable var, Int i)
    {
        typeof(this) ret;
        ret.variable = var;
        ret.value = ValueType(i);
        return ret;
    }

    ///
    Variable variable;
    ///
    ValueType value;
}

///
class Task
{
    ///
    this(CommandHolder[] c)
    {
        coms = c;
    }

    ///
    CommandHolder[] coms;
}

///
class CommandHolder
{
    ///
    this(string com, ReduceAction[] as)
    {
        command = com;
        actions = as;
    }

    ///
    string command;
    ///
    ReduceAction[] actions;
}

///
ReduceAction fork(Task cb, UserAction action)
{
    import std.process: spawnShell, wait;
    import std.array: array;
    import std.algorithm: map, fold;
    import std.stdio: writefln, writeln;
    writeln("AAA: ", cb.coms[0].command);
    const ras = cb.coms.map!((c) {
        // should handle stdout, stderr and input actions
        writefln("EXEC: `%s`", c.command);
        auto pid = spawnShell(c.command);
        auto code = wait(pid);
        auto out_ = "";
        auto err_ = "";
        // replace RETURN with the return code etc...
        auto toReduceAction(Action a, int c, string out_, string err_) 
        {
            return a;
        }
        auto ret = c.actions.map!(a => toReduceAction(a, code, out_, err_));
        return ret;
    }).array;
    return action;
    /*ras.fold!((acc, e) {
        return e;
    })(ReduceAction.init).array;*/
}

// https://techblog.zozo.com/entry/android-flux

// https://qiita.com/tkow/items/9da7062f9bfa99e848c3
// - 副作用は action creator で行う?

// http://www.enigmo.co.jp/blog/tech/reactredux約三年間書き続けたので知見を共有します/
// - `...、ActionCreator、...はすべて純粋な関数で書ける`
// - `副作用のある処理はすべて後述するMiddleware層に持っていける`
// - 上の記事と言っていることが違う…
//   - 結局 AC に副作用を持ち込んでいるっぽい

// ActionCreator == Dispatcher?

// https://super-yusuke.gitbook.io/udemy-course/redux-thunk-woita/redux-thunk-deniakushonwosuru#wosuakushonkurieitworu
// ActionCreator で　Store#dispatch を呼ぶ関数 (Action) を生成

// AC に副作用を持ち込むので問題ない気がしてきた


// Action Creator
// - Workflow, CommandLineTool ごとにある
// - actionType に対応する`メソッド`を作成
//   - 複数のメソッドを作成することもありうる
// - メソッド
//   - Action を生成
//   - dispatch(Action) を実行
//   - 副作用はここ
// Dispatcher
// - singleton
// Store
// - Workflow, CommandLineTool ごとにある
// - 一つの callback で複数 Store を更新するのは不味そうなので、
//   singleton の方が都合が良さそう
// callback は情報更新のみ

// Flux の Dispatcher: Redux 等の Store#dispatch
// Store(Flux): Reducer(Redux)
// - state を更新する
// Redux の場合は `combineReducers` で各コンポーネントごとの
// reducer をまとめた reducer を作成

// reduce は callback の一実装方法
// medal だと reduce で良さそう


// NewState から次の ActionCreator を動かすための機構が必要
// EventDispatcher とでも名前を付ける？

// EventQueue: [(Variable, Value)]

// EventDispatcher: (Variable, Value) -> ActionCreator[]

// ActionCreator: (payload, meta) -(invoke Method)-> [Action]

// Method: (side effect) -> Action

// Action: (type, payload, meta, error) // error が必要かは要議論

// payload, meta: (Variable, Value)

// reducer: State -> Action -> State

// 現状は Method 中に Action, reducer 相当も含まれてしまっている？
// Method: command, Action: inp, reducer: out

// 修正案
// EventDispatcher: State -> (Event, ActionCreator)
/// - singleton?
// Event = Action
// ActionCreator: Event -(invoke [Method])-> [Action]
// Action: (type, payload, meta, error)
// type: enum
// payload, meta: subset of State
// error: boolean? // 必要か？
// Method: Event -(side effect)-> Action
// reducer: State -> Action -> State
// State: [(Variable, Value)]
//// スライドさせるべきな気がする

// 修正案2
// ActionCreator: State -> Action[] (Redux Saga における User Action)
// Action: (type, payload, meta, error)
/// type: enum
/// payload, meta: subset of State
/// error: boolean? // 必要か？
// Dispatcher: Action -> Callback
// Callback: Action -(invoke Method[])-> Action[] // 返り値は Reducer Action
// Method: Action -(side effect)-> Action[] // 返り値は Reducer Action

// medal
/// ActionCreator に渡される Event 相当のものは、`State changed` のみ
/// ActionCreator が生成する Action は type, payload, error のみ？
//// ActionCreator は singleton
///// おそらく合成可能
//// 指定した payload に基づき Action を決定、同一 payload の場合は meta も指定する？
//// Dispatcher も singleton
///// おそらく合成可能
//// Callback も singleton
///// おそらく独立
/// Method では meta が要求されるかも

// https://prelude.hatenablog.jp/entry/2019/11/05/070000
// https://qiita.com/mpyw/items/a816c6380219b1d5a3bf

// Some term is imported from Flux, redux-saga