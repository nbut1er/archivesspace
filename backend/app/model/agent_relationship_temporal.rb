class AgentRelationshipTemporal < Sequel::Model(:related_agents_rlshp)

  include ASModel
  corresponds_to JSONModel(:agent_relationship_temporal)

end
