const VAR_ANNOTATIONS = Dict{Symbol, Any}()

macro annotate(note, stmt)
    if stmt.head == :(=) && length(stmt.args) == 2
        var = stmt.args[1]
        val = stmt.args[2]
        var_sym = QuoteNode(var)
        quote
            $(esc(var)) = $(esc(val))
            VAR_ANNOTATIONS[$var_sym] = $(esc(note))
        end
    else
        error("@annotate can only be used with assignments")
    end
end

function test()
    @annotate "constant" x = 1
    return VAR_ANNOTATIONS[:x] == "constant"
end
