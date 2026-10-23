from pathlib import Path
import tempfile
import unittest
from PIL import Image
from local_control_receipt import build,common_crop

class LocalCropContract(unittest.TestCase):
    def case(self):
        return {'id':'controls.sample.light.en-US','viewport':{'width':20,'height':20,'density':2},'captures':{p:{'admission':{'componentBounds':{'x':x,'y':5,'width':4,'height':3},'overlayRoleBounds':[]}} for p,x in [('react',3),('flutter-web',5)]}}
    def test_same_crop_keeps_both_controls_and_their_position_difference(self):
        css,pixels=common_crop(self.case())
        self.assertEqual(css,(1,3,11,10));self.assertEqual(pixels,(2,6,22,20))
    def test_unobserved_open_tooltip_retains_every_stage_pixel(self):
        case=self.case();case['surface']='tooltip'
        self.assertEqual(common_crop(case),((0,0,20,20),(0,0,40,40)))
        case['captures']['react']['admission']['overlayRoleBounds']=[{'rect':{'x':1,'y':10,'width':9,'height':6}}]
        self.assertEqual(common_crop(case),((0,0,20,20),(0,0,40,40)))
        case['captures']['flutter-web']['admission']['overlayRoleBounds']=[{'rect':{'x':2,'y':11,'width':0,'height':6}}]
        self.assertEqual(common_crop(case),((0,0,20,20),(0,0,40,40)))
        case['captures']['flutter-web']['admission']['overlayRoleBounds'][0]['rect']['width']=8
        self.assertNotEqual(common_crop(case)[0],(0,0,20,20))
    def test_crop_pixels_remain_identical_to_the_original_submatrix(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);case=self.case();image=Image.new('RGBA',(40,40))
            image.putdata([(i%256,(i//40)%256,111,255) for i in range(1600)]);src=root/'original.png';image.save(src)
            for c in case['captures'].values():c['image']=str(src)
            result=build({'name':'test','runId':'test','project':{},'cases':[case]},root/'crops')
            for c in result['cases'][0]['captures'].values():
                with Image.open(c['image']) as actual:self.assertEqual(actual.tobytes(),image.crop((2,6,22,20)).tobytes())
            with Image.open(src) as original:self.assertEqual(original.size,(40,40))
    def test_missing_pair_stays_missing_instead_of_getting_a_local_score(self):
        with tempfile.TemporaryDirectory() as tmp:
            case=self.case();del case['captures']['react']
            result=build({'name':'test','runId':'test','project':{},'cases':[case]},Path(tmp)/'out')
            self.assertEqual(result['cases'][0]['captures'],{})
            self.assertTrue(result['cases'][0]['captureErrors'])
if __name__=='__main__':unittest.main()
