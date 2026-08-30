-- WP0 为世界生成复用同一配置硬门。
-- 世界生成钩子有意延后到 WP1；当前阶段不能引入任何地图生成行为。
local AGON_WORLDGEN_ENABLED = GetModConfigData("enable_agon") == true

if AGON_WORLDGEN_ENABLED then
    -- 明确占位：WP0 不得改变生成地图；后续 WP 再在此处接入经过审核的钩子。
end
