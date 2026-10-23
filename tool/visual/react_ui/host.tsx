import React, {useState,useEffect} from 'react'
import {createRoot} from 'react-dom/client'
import {Button} from '@langgenius/dify-ui/button'
import {IconButton} from '@langgenius/dify-ui/icon-button'
import {Input} from '@langgenius/dify-ui/input'
import {Textarea} from '@langgenius/dify-ui/textarea'
import {Checkbox} from '@langgenius/dify-ui/checkbox'
import {Switch} from '@langgenius/dify-ui/switch'
import {Slider,SliderControl,SliderTrack,SliderIndicator,SliderThumb} from '@langgenius/dify-ui/slider'
import {NumberField,NumberFieldGroup,NumberFieldInput,NumberFieldIncrement,NumberFieldDecrement} from '@langgenius/dify-ui/number-field'
import {Tabs,TabsList,TabsTab,TabsPanel} from '@langgenius/dify-ui/tabs'
import {RadioGroup,Radio} from '@langgenius/dify-ui/radio-group'
import {Select,SelectTrigger,SelectValue,SelectPortal,SelectPositioner,SelectPopup,SelectList,SelectItem,SelectItemText,SelectItemIndicator} from '@langgenius/dify-ui/select'
import {ContextMenu,ContextMenuTrigger,ContextMenuContent,ContextMenuItem} from '@langgenius/dify-ui/context-menu'
import {Avatar} from '@langgenius/dify-ui/avatar'
import {ShortcutKbd} from '@/app/components/workflow/shortcuts/shortcut-kbd'
import {Kbd,KbdGroup} from '@langgenius/dify-ui/kbd'
import {StatusDot,StatusDotSkeleton} from '@langgenius/dify-ui/status-dot'
import {SegmentedControl,SegmentedControlItem} from '@langgenius/dify-ui/segmented-control'
import {Pagination} from '@langgenius/dify-ui/pagination'
import {Popover,PopoverTrigger,PopoverContent} from '@langgenius/dify-ui/popover'
import {Tooltip,TooltipProvider,TooltipTrigger,TooltipContent} from '@langgenius/dify-ui/tooltip'
import {DropdownMenu,DropdownMenuTrigger,DropdownMenuContent,DropdownMenuItem,DropdownMenuCheckboxItem,DropdownMenuCheckboxItemIndicator,DropdownMenuRadioGroup,DropdownMenuRadioItem,DropdownMenuRadioItemIndicator,DropdownMenuSeparator,DropdownMenuLabel,DropdownMenuGroup,DropdownMenuSub,DropdownMenuSubTrigger,DropdownMenuSubContent} from '@langgenius/dify-ui/dropdown-menu'
import {Dialog,DialogContent,DialogTitle,DialogDescription} from '@langgenius/dify-ui/dialog'
import {AlertDialog,AlertDialogContent,AlertDialogTitle,AlertDialogDescription,AlertDialogActions,AlertDialogCancelButton,AlertDialogConfirmButton} from '@langgenius/dify-ui/alert-dialog'
import Divider from '@/app/components/base/divider'
import {SkeletonRectangle} from '@/app/components/base/skeleton'
import {WorkspaceAvatar} from '@/app/components/base/workspace-avatar'
import TabSliderPlain from '@/app/components/base/tab-slider-plain'
import {useKeyboardSortable} from '@/app/components/base/keyboard-sortable/use-keyboard-sortable'
import i18n from 'i18next'
import {initReactI18next} from 'react-i18next'
import enCommon from '@/i18n/en-US/common.json'
import zhCommon from '@/i18n/zh-Hans/common.json'
import enTime from '@/i18n/en-US/time.json'
import zhTime from '@/i18n/zh-Hans/time.json'
import {SearchInput} from '@/app/components/base/search-input'
import {CheckboxList} from '@/app/components/base/checkbox-list'
import Chip from '@/app/components/base/chip'
import AppIcon from '@/app/components/base/app-icon'
import {CopyFeedback} from '@/app/components/base/copy-feedback'
import {Infotip} from '@/app/components/base/infotip'
import InlineDeleteConfirm from '@/app/components/base/inline-delete-confirm'
import TagInput from '@/app/components/base/tag-input'
import Loading from '@/app/components/base/loading'
import LoadingAnim from '@/app/components/base/chat/chat/loading-anim'
import Collapse from '@/app/components/header/account-setting/collapse'
import Calendar from '@/app/components/base/date-and-time-picker/calendar'
import CalendarHeader from '@/app/components/base/date-and-time-picker/date-picker/header'
import dayjs from 'dayjs'
import {QRCodeCanvas} from 'qrcode.react'
import {ToastHost,createToast,createToastManager} from '@langgenius/dify-ui/toast'
import {Drawer,DrawerContent,DrawerTitle,DrawerPortal,DrawerBackdrop,DrawerViewport,DrawerPopup,DrawerCloseButton} from '@langgenius/dify-ui/drawer'
import Badge from '@/app/components/base/badge'
import './production.css'
import './host.css'

const q=new URLSearchParams(location.search)
const kind=q.get('case')||'button-primary'
const label=q.get('lang')==='en-US'?'Create':'创建 Create'
const theme=q.get('theme')==='dark'?'dark':'light'
document.documentElement.dataset.theme=theme
// next-themes also sets native browser control color-scheme in production.
document.documentElement.style.colorScheme=theme
// Match the production layout's <html lang={locale}> so Chromium selects regional CJK glyphs.
document.documentElement.lang=q.get('lang')||'en-US'
i18n.use(initReactI18next).init({lng:q.get('lang')==='en-US'?'en':'zh',defaultNS:'common',resources:{en:{common:enCommon,time:enTime},zh:{common:zhCommon,time:zhTime}},interpolation:{escapeValue:false}})
const tm=createToastManager()
function SortExample(){const x=useKeyboardSortable({items:['Alpha','Beta'],onChange:()=>{}});return <div className="w-75">{x.announcement}{x.items.map((item,i)=><div key={i} className="system-sm-regular">{item}</div>)}</div>}
function Example(){
 useEffect(()=>{if(kind==='toast')createToast(tm).success(label,{description:'Example content',timeout:0})},[])

 const [input,setInput]=useState(''),[value,setValue]=useState('a')
 const disabled=kind.endsWith('-disabled')
 if(kind.startsWith('button-'))return <Button variant={(kind.split('-')[1]==='disabled'?'primary':kind.split('-')[1]) as any} disabled={disabled}>{label}</Button>
 if(kind==='icon-button')return <IconButton aria-label="Add"><span className="i-ri-add-line size-4"/></IconButton>
 if(kind.startsWith('input'))return <div className="w-75"><Input aria-label="Input" placeholder={label} value={input} onValueChange={setInput} disabled={disabled}/></div>
 if(kind==='textarea')return <div className="w-75"><Textarea aria-label="Textarea" placeholder={label} value={input} onChange={e=>setInput(e.target.value)}/></div>
 if(kind.startsWith('checkbox')&&kind!=='checkbox-list')return <Checkbox aria-label="Checkbox" checked={kind==='checkbox-checked'} indeterminate={kind==='checkbox-indeterminate'} disabled={disabled}/>
 if(kind.startsWith('switch'))return <Switch aria-label="Switch" checked={kind==='switch-checked'} disabled={disabled}/>
 if(kind==='slider')return <Slider defaultValue={30} className="w-75"><SliderControl><SliderTrack><SliderIndicator/></SliderTrack><SliderThumb aria-label="Slider"/></SliderControl></Slider>
 if(kind==='number-field')return <NumberField defaultValue={13}><NumberFieldGroup className="w-75"><NumberFieldInput aria-label="Number"/><div className="flex flex-col"><NumberFieldIncrement aria-label="Increase"/><NumberFieldDecrement aria-label="Decrease"/></div></NumberFieldGroup></NumberField>
 if(kind==='badge')return <Badge>{label}</Badge>
 if(kind==='tabs')return <Tabs defaultValue="a"><TabsList><TabsTab value="a">{label}</TabsTab><TabsTab value="b">Other</TabsTab></TabsList><TabsPanel value="a"/></Tabs>
 if(kind==='radio')return <RadioGroup value="a"><Radio value="a" aria-label="A"/><Radio value="b" aria-label="B"/></RadioGroup>
 if(kind==='select')return <Select items={[{label:'Option A',value:'a'},{label:'Option B',value:'b'}]} value={value} onValueChange={v=>setValue(v||'a')}><SelectTrigger className="w-75"><SelectValue/></SelectTrigger><SelectPortal><SelectPositioner><SelectPopup><SelectList>{[{label:'Option A',value:'a'},{label:'Option B',value:'b'}].map(x=><SelectItem key={x.value} value={x.value}><SelectItemText>{x.label}</SelectItemText><SelectItemIndicator/></SelectItem>)}</SelectList></SelectPopup></SelectPositioner></SelectPortal></Select>

 if(kind==='avatar')return <Avatar name="Alice" avatar={null}/>
 if(kind==='workspace-avatar')return <WorkspaceAvatar name="Alice"/>
 if(kind==='shortcut-kbd')return <ShortcutKbd hotkey="Ctrl+K" platform="linux"/>
 if(kind==='kbd')return <KbdGroup><Kbd>Ctrl</Kbd><Kbd>K</Kbd></KbdGroup>
 if(kind==='status-dot')return <div className="flex gap-3">{['success','warning','error','normal','disabled'].map(s=><StatusDot key={s} status={s as any}/>) }<StatusDotSkeleton/></div>
 if(kind==='skeleton')return <SkeletonRectangle className="w-75"/>
 if(kind==='divider')return <div className="w-75"><Divider/></div>
 if(kind==='segmented-control')return <SegmentedControl value="a"><SegmentedControlItem value="a">{label}</SegmentedControlItem><SegmentedControlItem value="b">Other</SegmentedControlItem></SegmentedControl>
 if(kind==='tab-slider-plain')return <TabSliderPlain value="a" onChange={()=>{}} options={[{value:'a',text:label},{value:'b',text:'Other'}]} noBorderBottom/>
 if(kind==='pagination')return <Pagination page={2} totalPages={10} onPageChange={()=>{}}/>
 if(kind==='text'||kind==='selection')return <span className="system-sm-regular text-text-primary">{label} ABC 0123</span>
 if(kind==='surface')return <div className="rounded-xl border border-divider-regular bg-components-panel-bg p-4 backdrop-blur-[5px] system-sm-regular text-text-primary">{label}</div>
 if(kind==='dashed-border')return <div className="rounded-xl border border-dashed border-components-dropzone-border bg-components-dropzone-bg p-4 system-sm-regular text-text-primary">{label}</div>
 if(kind==='popover')return <Popover open><PopoverTrigger render={<Button/>}>{label}</PopoverTrigger><PopoverContent className="p-4">{label}</PopoverContent></Popover>
 if(kind==='tooltip')return <TooltipProvider><Tooltip open><TooltipTrigger render={<Button/>}>{label}</TooltipTrigger><TooltipContent placement="bottom">{label}</TooltipContent></Tooltip></TooltipProvider>
 if(kind==='menu')return <DropdownMenu open><DropdownMenuTrigger render={<Button/>}>{label}</DropdownMenuTrigger><DropdownMenuContent placement="bottom-start" className="w-60"><DropdownMenuGroup><DropdownMenuLabel>{label}</DropdownMenuLabel><DropdownMenuItem>{label}</DropdownMenuItem></DropdownMenuGroup><DropdownMenuCheckboxItem checked><DropdownMenuCheckboxItemIndicator/>{label}</DropdownMenuCheckboxItem><DropdownMenuSeparator/><DropdownMenuRadioGroup value="a"><DropdownMenuRadioItem value="a"><DropdownMenuRadioItemIndicator/>Option A</DropdownMenuRadioItem><DropdownMenuRadioItem value="b"><DropdownMenuRadioItemIndicator/>Option B</DropdownMenuRadioItem></DropdownMenuRadioGroup></DropdownMenuContent></DropdownMenu>
 if(kind==='dialog')return <Dialog open><DialogContent><DialogTitle className="system-sm-regular text-text-primary">{label}</DialogTitle><DialogDescription className="system-sm-regular text-text-primary">Example content</DialogDescription></DialogContent></Dialog>
 if(kind==='alert-dialog')return <AlertDialog open><AlertDialogContent><div className="flex flex-col gap-2 px-6 pb-4 pt-6"><AlertDialogTitle className="w-full truncate title-2xl-semi-bold text-text-primary">{label}</AlertDialogTitle><AlertDialogDescription className="system-md-regular text-text-tertiary">Example content</AlertDialogDescription></div><AlertDialogActions><AlertDialogCancelButton>Cancel</AlertDialogCancelButton><AlertDialogConfirmButton>Delete</AlertDialogConfirmButton></AlertDialogActions></AlertDialogContent></AlertDialog>

 if(kind==='search-input')return <SearchInput value="" onValueChange={()=>{}} placeholder={label} className="w-75"/>
 if(kind==='checkbox-list')return <div className="w-75"><CheckboxList title={label} options={[{label:'Option A',value:'a'},{label:'Option B',value:'b'}]} value={['a']} showSearch={false}/></div>
 if(kind==='chip')return <Chip value="a" items={[{value:'a',name:label}]} onSelect={()=>{}} onClear={()=>{}}/>
 if(kind==='app-icon')return <AppIcon iconType="emoji" icon="🤖" background="#FFEAD5"/>
 if(kind==='copy-feedback')return <CopyFeedback content="Example content" copyLabel="Copy" copiedLabel="Copied"/>
 if(kind==='infotip')return <Infotip aria-label="Help">{label}</Infotip>
 if(kind==='inline-delete-confirm')return <InlineDeleteConfirm title={label} onConfirm={()=>{}} onCancel={()=>{}} className="m-0 w-75 border-0 shadow-none"/>
 if(kind==='tag-input')return <div className="w-75"><TagInput items={['Alpha','Beta']} onChange={()=>{}} placeholder={label}/></div>
 if(kind==='loading')return <div className="w-75"><Loading/></div>
 if(kind==='loading-anim')return <LoadingAnim type="text"/>
 if(kind==='spinner')return <span className="i-ri-loader-2-line size-4 animate-spin"/>
 if(kind==='qrcode')return <QRCodeCanvas value="https://example.test/ui-parity" size={160} level="L"/>
 if(kind==='collapse')return <div className="w-75"><Collapse title={label} items={[{key:'a',name:'Alpha'}]} renderItem={x=>x.name}/></div>
 if(kind==='calendar') {const selected=dayjs('2026-10-15'),start=dayjs('2026-09-27');return <div className="mt-1 w-63 rounded-xl border-[0.5px] border-components-panel-border bg-components-panel-bg shadow-lg"><CalendarHeader currentDate={selected} handleOpenYearMonthPicker={()=>{}} onClickNextMonth={()=>{}} onClickPrevMonth={()=>{}}/><Calendar days={Array.from({length:42},(_,i)=>({date:start.add(i,'day'),isCurrentMonth:start.add(i,'day').month()===9}))} selectedDate={selected} onDateClick={()=>{}}/></div>}
 if(kind==='toast')return <ToastHost manager={tm} timeout={0}/>
 if(kind==='drawer')return <Drawer open swipeDirection="right"><DrawerPortal><DrawerBackdrop className="fixed"/><DrawerViewport><DrawerPopup><DrawerContent><DrawerTitle className="system-sm-regular text-text-primary">{label}</DrawerTitle><p className="system-sm-regular text-text-primary">Example content</p><DrawerCloseButton/></DrawerContent></DrawerPopup></DrawerViewport></DrawerPortal></Drawer>
 if(kind==='table')return <div className="w-100 overflow-x-auto"><table className="w-full min-w-110 border-collapse"><thead className="system-xs-medium-uppercase text-text-tertiary bg-background-section-burn"><tr><th className="rounded-l-lg py-1.5 pl-3 text-left">Name</th><th className="rounded-r-lg py-1.5 pl-3 text-left">Status</th></tr></thead><tbody className="system-sm-regular text-text-secondary"><tr className="border-b border-divider-subtle"><td>Alpha</td><td>Ready</td></tr></tbody></table></div>

 if(kind==='reorderable-list')return <SortExample/>
 if(kind==='labeled-switch')return <div className="flex w-100 items-center gap-2 py-2"><div className="grow"><div className="system-sm-medium text-text-secondary">{label}</div><div className="system-xs-regular text-text-tertiary">Example content</div></div><Switch checked/></div>
 if(kind==='toolbar')return <div className="w-100 overflow-x-auto"><div className="flex w-max gap-2"><Button>{label}</Button><Button>Other</Button></div></div>

 if(kind==='menu-submenu')return <DropdownMenu open><DropdownMenuTrigger render={<Button/>}>{label}</DropdownMenuTrigger><DropdownMenuContent placement="bottom-start" className="w-60"><DropdownMenuSub open><DropdownMenuSubTrigger>{label}</DropdownMenuSubTrigger><DropdownMenuSubContent><DropdownMenuItem>Option A</DropdownMenuItem></DropdownMenuSubContent></DropdownMenuSub></DropdownMenuContent></DropdownMenu>
 if(kind==='context-menu')return <ContextMenu><ContextMenuTrigger className="inline-block"><Button>{label}</Button></ContextMenuTrigger><ContextMenuContent className="w-60"><ContextMenuItem>Option A</ContextMenuItem></ContextMenuContent></ContextMenu>
 throw new Error('No actual reference component registered: '+kind)
}
createRoot(document.getElementById('root')!).render(<div id="parity-stage"><div id="parity-component"><Example/></div></div>)
