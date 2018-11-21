/**
 * This script restores default RS configuration with equal 1 priority and votes for all members of a replica set
 */

var conf = rs.conf();
for (var i=0; i < conf.members.length; i++) {conf.members[i].priority = 1;conf.members[i].votes = 1;};
rs.reconfig(conf, {force:1})
