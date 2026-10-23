import unittest
from check_ui_coverage import validate,validate_public_classes
from pathlib import Path
import tempfile

class InventoryContract(unittest.TestCase):
    def setUp(self):
        self.actual={'exports':{'control.dart'},'pages':set(),'nodeBodies':set()}
        self.inventory={'exports':[{'source':'control.dart','cases':['controls.sample']}],'pages':[],'nodeBodies':[]}
        self.catalogs=[[{'id':'controls.sample'}]]
    def test_new_export_cannot_silently_escape_the_inventory(self):
        self.actual['exports'].add('new-control.dart')
        self.assertTrue(any('new-control.dart' in e for e in validate(self.inventory,self.catalogs,self.actual)))
    def test_typo_or_removed_case_is_rejected(self):
        self.assertTrue(any('Unknown case' in e for e in validate(self.inventory,[],self.actual)))
    def test_nonvisual_escape_requires_an_explanation(self):
        self.inventory['exports'][0]={'source':'control.dart','visual':False}
        self.assertTrue(any('reason' in e for e in validate(self.inventory,self.catalogs,self.actual)))
    def test_declarations_do_not_require_a_successful_capture(self):
        # Image outcomes belong to the Raft report. A declared failing case stays in the matrix.
        self.catalogs[0][0]['captureErrors']=['Known failure']
        self.assertEqual(validate(self.inventory,self.catalogs,self.actual),[])
    def test_a_new_class_inside_an_existing_export_needs_a_coverage_review(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'control.dart').write_text('class Known {}\nclass NewControl {}\n')
            inventory={'exports':[{'source':'control.dart','publicClasses':['Known']}]}
            errors=validate_public_classes(inventory,root)
        self.assertTrue(any('NewControl' in e for e in errors))
if __name__=='__main__' :unittest.main()
