module net.network;

///
class Network
{
    ///
    this() @disable
    {

    }

    ///
    typeof(this) load(string file)
    {
        return null;
    }
private:
    Store store;
}

class Store
{
    Variable[] variables;
}

// reduce: action -> state -> state
class Reducer
{
    void reduce(string action)
    {

    }
private:
    Store store;
}

class Variable
{
    immutable string namespace;
    immutable string name;
    Type value; /// Int(3), String("success") etc...
}

// https://techblog.zozo.com/entry/android-flux

// https://qiita.com/tkow/items/9da7062f9bfa99e848c3
// - 副作用は action creator で行う?

// http://www.enigmo.co.jp/blog/tech/reactredux約三年間書き続けたので知見を共有します/
// - `...、ActionCreator、...はすべて純粋な関数で書ける`
// - `副作用のある処理はすべて後述するMiddleware層に持っていける`
// - 上の記事と言っていることが違う…
//   - 結局 AC に副作用を持ち込んでいるっぽい
