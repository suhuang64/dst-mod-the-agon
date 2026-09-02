-- WP5 TestMode：构造一个只属于当前 Instance 的 Group 投票。

local TestModeDecisions = {}

function TestModeDecisions.CreateGroupVote(runtime, decision_id, candidates, options)
    if runtime == nil or runtime.services == nil
        or runtime.services.decision == nil
        or runtime.group == nil then
        return nil, "TEST_MODE_DECISION_SERVICE_UNAVAILABLE"
    end
    options = type(options) == "table" and options or {}
    local decision_options = {}
    for key, value in pairs(options) do
        decision_options[key] = value
    end
    decision_options.decision_id = decision_id
    decision_options.decision_type = "GROUP_VOTE"
    decision_options.group_id = runtime.group:GetId()
    decision_options.candidates = candidates
    return runtime.services.decision:Create(decision_options)
end

return TestModeDecisions
