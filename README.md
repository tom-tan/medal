# What is this?
This is a template to develop D applications with VSCode with remote container extension.

## TODO
- 用語の整理
  - 名前空間？
    - step.cat の ExecutionState と step.sort1 の ExecutionState を区別したい
    - シグナルのみ global state?
    - シグナル自体は in なしの transition 扱い
      - action-creator で action に変換する仕組みがほしい
    - ログの `id` と namespace が混在するのはよくない？
      - logger による id の扱いなど
  - 遷移図
    - 単体で遷移図として成り立つもの
      - CommandLineTool など
    - 他の遷移図と組み合わせて使うもの
      - Workflow など
    - 遷移図に injection かけるやつ
      - cwl-metrics 拡張など
    - ペトリネットと同値のはずだが、実装上は primary/secondary input が出てきている
  - Flux 周り
    - 変更点から action を決定する action-creator 周り
      - (var, val) -> action に名前がほしい
        - dispatcher は Flux と名前がかぶるので避けたい
        - mapper?
    - action を構成する各コマンドを表す名前
      - 単に `command` でもいい？

- 複数マージできるようにしたい
  - マージルールの定義
    - マージ後の遷移図も同一形式で記述可能にしておきたい

- store の各変数の型の洗い出し
  - `File` は本当に必要なのか
  - `any` は必要なのか
  - ユーザー定義型は当面は考えない
    - `Foo("bar", 4)` みたいなやつ

- 遷移の種類の洗い出し
  - 決め打ちで特定の状態に遷移する
    - foo=a -> bar=a
  - 入力の状態の一部をそのまま伝播させる
    - foo=$a -> bar=$a など
  - 入力を加工して値を生成する
    - `jq '.output' foo.txt` など
  - 本当に副作用が主目的
    - クラウド上にインスタンスを確保する場合など
  - medal 上で区別する必要があるかは不明

- ログ加工用の DSL
  - Lua
  - JS or TS
  - インラインに書けるようにするのか、別ファイルに分けるのか
  - 実行には(ep3 のデバッグ時以外には)関係ないため、優先度は低い
