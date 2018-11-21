/**
 * This script sets votes and priority to 0 for all unreacheable memeber of rs. That allows to elect new primary member in case of lost majority.
 */

var conf = rs.conf();
var status = rs.status();
var bad = status.members.filter(function (d) {return d.stateStr == "(not reachable/healthy)"});
bad.forEach(function(b) { for (var i=0; i < conf.members.length; i++) {if (conf.members[i].host === b.name) {conf.members[i].priority = 0;conf.members[i].votes = 0;break;}}});
rs.reconfig(conf, {force:1})
