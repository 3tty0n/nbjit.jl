begin
    x = 1
    @hole y = 100
    @hole z = x + y # TODO: check (constant, constant)
end

begin
    x = 1
    y = 200 # HOLE (x, y)
    z = x + y
end

begin
    x = 1
    y = 300 # HOLE (x, y)
    z = x + y # x -> 1
end

# guard(x is unchanged)
begin
    x = 1
    x = x * 3 # HOLE (x, y)
              # x を書き換えているので伝搬をストップ
    z = x + y
end

# HOLE の特定 and 分割
# 定数伝搬
# 分割コンパイル
# リンク

# 1回目: いつも通り
# 2回目: HOLE の特定 -> HOLE 付き定数伝搬 -> 分割コンパイル -> ... (slow path)
# 3回目: guard の検査 -> 再利用する or 2回目と同じプロセス
#        - 再利用 (fast path): HOLE の部分だけソースコードを切り出す
#                             -> 分割コンパイル -> リンク
#        - 再利用しない (slow path): 定数伝搬の仮説 (HOLE が伝搬した変数を書き換え
#          ていないか) を破っている場合
# 4回目以降: 3回目と同じ

# HOLE を貼り合わせるのは別の話
# - ソースコードレベル
# - IR のレベル
# - バイナリのレベル

# 再コンパイルがどのくらい走ったのか？
# - 最適化のconfigurationがどのくらい必要なのか
# - 再利用されないなら軽い最適化のみ使う
# - 再利用されるなら高価な最適化もやる

# argument: HOLE (check whether HOLE doesn't use x)
# TODO: free variables
begin
    x = heavy_comp() # check heavy_comp doesn't have side-effect (POC として副作用がないことを仮定してもいい)
    {{{ HOLE }}} # HOLE is a "missing" exprssion that will be eidted later
    z = x + y
end

global: {x: glob0} # glob0 is the result of heavy_comp()

guard(x is unchanged)
guard(x is not used in HOLE)
begin
    {{{ HOLE }}} # HOLE is a "missing" exprssion that will be eidted later
    z = x + y
end

# Julia AST -> partially-evaluated AST (with hole) -> LLVM -> native

# first, do the high-level part
#   - HOLE detection, guard, free-variable analysis, etc.
# as well as the first step, detect the HOLE part between the two ASTs
# second, do the low-level part: patching binaries
#   - HOLE is will be compiled later separately and patched
