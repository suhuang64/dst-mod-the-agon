-- WP5 TestMode：提供只修改 TestMode 私有计数的 Effect handler。

local TestModeEffects = {}

function TestModeEffects.CreateCounterHandler(runtime)
    return
    {
        Apply = function(_, effect)
            runtime.effect_apply_count = runtime.effect_apply_count + 1
            effect.test_counter_applied = true
            return true
        end,
        Remove = function(_, effect)
            if effect.test_counter_applied then
                runtime.effect_remove_count = runtime.effect_remove_count + 1
                effect.test_counter_applied = false
            end
            return true
        end,
    }
end

return TestModeEffects
