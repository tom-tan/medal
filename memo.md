
// ActionType と Payload の取りうる値が異なる
// UserAction // action-creator で生成される
// - type: any string
// - payload: any
// ReduceAction // commands#payload
// - type: modify or system
// - payload: any or RETURN, STDOUT, STDERR
// Event // action-creator
// - type: modify
// - payload: pattern <- payload よりも pattern の方が適切


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

// Petri nets: http://www.peterlongo.it/Italiano/Informatica/Petri/index.html
# Gap between Petri nets and the model for Medal
懸念事項: ちゃんとしたペトリネットではない！
- timed Petri nets (発火継続時間モデル)と近いが、以下の点が異なる
  - timed Petri nets
    - 発火可能になると入力プレースからトークンが消費される
      - 入力プレースからトランジションへのトークンの移動
    - 一定時間後に出力プレースにトークンがトランジションから移動する
    - 同一プレースに複数トークンが現れうる
    - Rust の move と対応？
  - medal モデル
    - 発火可能になっても入力プレースからトークンが消費されない
    - 一定時間後に出力プレースにトークンが**追加で**現れる
    - 同一プレースにはトークンは高々一つ
    - 既存のプログラミング言語のモデリングはこちらに近い
    - Rust の borrow と対応？



# Log
- medal log
  - start/end event
  - error event
    - unmatched type
    - uncaughted failure
    - invalid input format
- user log

- nothing: --quiet
- only user log: default
- user log and error event: verbose
- all: user log, error event and start/end event: veryverbose

# Global States
- namespace: medal # it is reserved by medal
  - variable: exit
    type: int
    Note:
      - captured by the engine
      - terminate the engine with the given code
      - 複数 namespace からここへの遷移がある場合には、内部的には $namespace.exit -(全ての exit を入力とする tr)-> medal.exit
  - variable: signal
    type: int or enum
    Note: only valid if `configuration` has `catch-signal: [INT, TERM]`
    - 異なる namespace に遷移する場合の挙動は？
    - 内部的には medal.signal -> $namespace.signal (各 namespace ごと)
  - exit と signal は namespace ごとに reserved でも良さそう
