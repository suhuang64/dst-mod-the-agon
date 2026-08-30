---@diagnostic disable: lowercase-global

name = "The Agon"
description = "The Agon 公共底座"
author = "The Agon"
version = "0.1.0"
api_version = 10

dont_starve_compatible = false
reign_of_giants_compatible = false
shipwrecked_compatible = false
dst_compatible = true

client_only_mod = false
all_clients_require_mod = true

configuration_options =
{
    {
        name = "enable_agon",
        label = "启用 The Agon",
        hover = "仅在目标 shard 启用 The Agon 公共底座。",
        options =
        {
            { description = "关闭", data = false, hover = "不启动 The Agon server runtime。" },
            { description = "开启", data = true, hover = "启动 The Agon server runtime。" },
        },
        default = false,
    },
}
