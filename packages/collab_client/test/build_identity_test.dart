import 'package:collab_client/collab_client.dart';
import 'package:test/test.dart';
void main() {
  test('old servers report no release and cannot advertise unconfigured Agent capabilities', () {
    final value=SystemFeatures.fromJson(<String,Object?>{});
    expect(value.build,isNull);expect(value.inlineAgent,isFalse);expect(value.inlineAgentShell,isFalse);
  });
  test('public release fields stay bounded and malformed or secret shaped fields are rejected', () {
    final value=SystemFeatures.fromJson({'build':{'revision':'a'*40,'workflow_protocol':'1.21','agent_protocol':'dify-sf-agent/1'},'inline_agent':true,'inline_agent_shell':false});
    expect(value.build!.revision,'a'*40);expect(value.build!.workflowProtocol,'1.21');expect(value.inlineAgent,isTrue);expect(value.inlineAgentShell,isFalse);
    expect(ServerBuildIdentity.fromJson({'revision':'Bearer private value'}),isNull);
    expect(ServerBuildIdentity.fromJson({'revision':'a'*40,'agent_protocol':'secret: user@example.invalid'})!.agentProtocol,'');
    expect(ServerBuildIdentity.fromJson({'revision':'development'})!.workflowProtocol,'');
  });
}
