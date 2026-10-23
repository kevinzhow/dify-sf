from pathlib import Path
import unittest
from unittest.mock import patch
import assemble_ui_receipt as audit

class ReceiptContract(unittest.TestCase):
    def setUp(self):
        self.cid='controls.sample.light.en-US'
        self.case={'id':self.cid,'title':'sample','captureType':'component-fixture','theme':'light','locale':'en-US','state':'default','fixtureSha256':None}
        self.catalog=({self.cid:self.case},{'exports':[],'pages':[],'nodeBodies':[]})
    def run_rows(self,rows):
        with patch.object(audit,'expected_cases',return_value=self.catalog),patch.object(audit,'read_rows',side_effect=rows),patch.object(audit,'superseded_cases',return_value={}):
            return audit.assemble([Path(str(i)) for i in range(len(rows))])
    def test_latest_failure_is_not_replaced_with_an_older_success(self):
        good={'id':self.cid,'captures':{'react':{'image':'/owned/react.png'},'flutter-web':{'image':'/owned/flutter.png'}}}
        bad={'id':self.cid,'captures':{},'captureErrors':['final state was absent']}
        receipt,coverage=self.run_rows([[good],[bad]])
        self.assertEqual(receipt['cases'][0]['captures'],{})
        self.assertEqual(coverage['pairedCases'],0)
        self.assertEqual(len(coverage['attempts'][self.cid]),2)
    def test_an_unattempted_declared_case_blocks_a_final_receipt(self):
        with self.assertRaisesRegex(ValueError,'no attempt'):
            self.run_rows([[]])
    def test_unknown_provider_cannot_inflate_paired_counts(self):
        with self.assertRaisesRegex(ValueError,'Unexpected provider'):
            self.run_rows([[{'id':self.cid,'captures':{'other':{'image':'/owned/x.png'}}}]])
    def test_only_an_explicit_supersession_can_preserve_an_old_attempt(self):
        old='controls.wrong-reference.light.en-US'
        decision={old:{'reason':'Wrong source control','referenceEvidence':'source.dart / source.tsx','replacement':[self.cid]}}
        rows=[{'id':old,'captures':{'react':{'image':'/owned/old.png'}}},{'id':self.cid,'captures':{}}]
        with patch.object(audit,'expected_cases',return_value=self.catalog),patch.object(audit,'read_rows',return_value=rows),patch.object(audit,'superseded_cases',return_value=decision):
            receipt,coverage=audit.assemble([Path('first')])
        self.assertEqual(coverage['declaredCases'],1)
        self.assertEqual(coverage['attemptedCases'],1)
        self.assertIn(old,coverage['supersededAttempts'])
        self.assertEqual(len(receipt['cases']),1)
    def test_an_unlisted_unknown_case_is_rejected(self):
        with self.assertRaisesRegex(ValueError,'outside the declared matrix'):
            self.run_rows([[{'id':'controls.unknown.light.en-US','captures':{}}]])
    def test_metadata_describes_the_actual_clip_not_the_whole_canvas_anchor(self):
        capture={'box':{'x':248,'y':0,'width':1192,'height':900},'environment':{'width':1440,'height':900,'dpr':2}}
        crop=audit.normalized_crop(capture,{'region':[60,64,940,700]})
        self.assertEqual(crop['origin'],{'x':308,'y':64,'width':940,'height':700})
        self.assertEqual(crop['canvasAnchor']['width'],1192)
if __name__=='__main__'  :unittest.main()
