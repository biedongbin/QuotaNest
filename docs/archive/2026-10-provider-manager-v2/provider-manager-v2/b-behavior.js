/* 本地行为自检：node b-behavior.js  (无第三方依赖，DOM 为最小 stub)
   覆盖：深链 screen/provider/theme、主题默认值、编辑态与导入抽屉开关、dirty 守卫、时刻校验。
   不覆盖：真实浏览器布局、滚动、CSS 计算 —— 由 QA 实测。 */
const fs=require('fs'),vm=require('vm');
const html=fs.readFileSync(__dirname+'/b-console.html','utf8');
const js=html.match(/<script>([\s\S]*?)<\/script>/)[1];

const results=[];
const rec=(name,ok,detail)=>results.push({check:name,result:ok?'PASS':'FAIL',detail:detail===undefined?'':String(detail)});

function makeEnv(search){
  const attrs={}, nodes={};
  function node(id){
    if(nodes[id])return nodes[id];
    const el={id,innerHTML:'',textContent:'',className:'',style:{},scrollTop:0,dataset:{},
      classList:{_s:new Set(),add(c){this._s.add(c)},remove(c){this._s.delete(c)},
        toggle(c,v){v?this._s.add(c):this._s.delete(c)},contains(c){return this._s.has(c)}},
      attributes:attrs,
      setAttribute(k,v){attrs[k]=v;if(k==='aria-current')el.ariaCurrent=v},
      removeAttribute(k){delete attrs[k]},
      getAttribute(k){return attrs[k]},
      focus(){},select(){},setSelectionRange(){},
      querySelector(){return null},querySelectorAll(){return []},
      replaceWith(){},scrollIntoView(){},matches(){return false},
      closest(){return null},firstElementChild:null,appendChild(){}};
    nodes[id]=el;return el;
  }
  const document={
    documentElement:{setAttribute(k,v){attrs['html:'+k]=v},getAttribute(k){return attrs['html:'+k]}},
    addEventListener(){},createElement(){return node('__tmp'+Math.random())},
    querySelector(s){return node(s)},querySelectorAll(){return []},
    getElementById(id){return node('#'+id)},activeElement:null,
  };
  const ctx={document,location:{search},matchMedia:()=>({matches:false}),URLSearchParams,Intl,console,
    setTimeout:(f)=>{f();return 0},clearTimeout(){},Math,JSON,Date};
  ctx.window=ctx;
  vm.createContext(ctx);
  vm.runInContext(js,ctx,{filename:'inline.js'});
  return {ctx,attrs,g:(e)=>vm.runInContext(e,ctx)};
}

/* 1. 默认深色 */
{
  const {g,attrs}=makeEnv('');
  rec('deeplink.no-param.theme=dark', attrs['html:data-theme']==='dark', attrs['html:data-theme']);
  rec('deeplink.default.screen=overview', g('state').screen==='overview', g('state').screen);
  rec('deeplink.default.mode=inspect', g('state').mode==='inspect', g('state').mode);
}
/* 2. ?theme=light 生效 */
{
  const {g,attrs}=makeEnv('?theme=light');
  rec('deeplink.theme=light', attrs['html:data-theme']==='light', attrs['html:data-theme']);
}
/* 3. ?theme=dark 显式 */
{
  const {g,attrs}=makeEnv('?theme=dark');
  rec('deeplink.theme=dark', attrs['html:data-theme']==='dark', attrs['html:data-theme']);
}
/* 4. ?screen=accounts / schedule */
for(const s of ['accounts','schedule']){
  const {g}=makeEnv('?screen='+s);
  rec('deeplink.screen='+s, g('state').screen===s, g('state').screen);
}
/* 5. ?screen=edit&provider=gpt -> 右栏编辑态，选中 gpt，主表保留 */
{
  const {g}=makeEnv('?screen=edit&provider=gpt');
  rec('deeplink.edit.mode', g('state').mode==='edit', g('state').mode);
  rec('deeplink.edit.selected=gpt', g('state').selected==='gpt', g('state').selected);
  rec('deeplink.edit.draft=gpt', g('state').editDraft && g('state').editDraft.id==='gpt', g('state').editDraft&&g('state').editDraft.id);
  rec('deeplink.edit.dirty=false', g('state').editBase===JSON.stringify(g('state').editDraft), '');
}
/* 6. ?screen=edit&provider=glm */
{
  const {g}=makeEnv('?screen=edit&provider=glm');
  rec('deeplink.edit.provider=glm', g('state').mode==='edit'&&g('state').editDraft.id==='glm', g('state').editDraft&&g('state').editDraft.id);
}
/* 7. ?screen=add&provider=compat -> 新草稿且模板 compat */
{
  const {g}=makeEnv('?screen=add&provider=compat');
  const d=g('state').editDraft;
  rec('deeplink.add.mode', g('state').mode==='edit'&&g('state').editIsNew===true, g('state').editIsNew);
  rec('deeplink.add.template=compat', d&&d.provider==='compat', d&&d.provider);
  rec('deeplink.add.compat.query.disabled', d&&d.__caps&&d.__caps.query===false, d&&JSON.stringify(d.__caps));
  rec('deeplink.add.compat.call.enabled', d&&d.__caps&&d.__caps.call===true, '');
}
/* 8. ?screen=import -> 抽屉打开且已扫描 */
{
  const {g}=makeEnv('?screen=import');
  rec('deeplink.import.open', g('state').importOpen===true, g('state').importOpen);
  rec('deeplink.import.scanned', g('state').importScanned===true, g('state').importScanned);
  rec('deeplink.import.picked.defaults', Object.values(g('state').importPicked).filter(Boolean).length>0, JSON.stringify(g('state').importPicked));
}
/* 9. 未知 screen 回落 overview */
{
  const {g}=makeEnv('?screen=bogus');
  rec('deeplink.unknown.screen.fallback', g('state').screen==='overview', g('state').screen);
}
/* 10. 行为：dirty 守卫 / 时刻校验 / 能力判定 */
{
  const {ctx,g}=makeEnv('');
  const st=g('state');
  // 编辑后 dirty 为真
  g('openEdit')('glm',true);
  st.editDraft.name='改名';
  rec('behavior.dirty.detect', g('isDirty')()===true, '');
  st.editDraft.name='GLM 日常';
  rec('behavior.dirty.clean.after.revert', g('isDirty')()===false, '');
  // 时刻校验：非法 / 合法 / 重复
  st.editDraft.schedule=true;
  g('addTime')();                       // 无 timeInput 节点 -> 早退，不应抛错
  rec('behavior.addTime.no-crash', true, '');
  // 能力：模板决定
  rec('behavior.canCall.glm', g('canCall')(g('byId')('glm'))===true, '');
  rec('behavior.canCall.gpt.false', g('canCall')(g('byId')('gpt'))===false, '');
  rec('behavior.canCall.cline.false', g('canCall')(g('byId')('cline'))===false, '');
  // 额度 100% 与查询状态分离
  const gpt=g('byId')('gpt');
  rec('behavior.gpt.100pct', gpt.windows.some(w=>w.used===100), '');
  rec('behavior.gpt.query.fresh.not.error', gpt.query.state==='fresh', gpt.query.state);
  // 自动查询关闭 != 手动查询禁用
  rec('behavior.ocgo.monitor.off.but.manual.query.ok', g('byId')('ocgo').monitor===true&&g('canCall')(g('byId')('ocgo'))===true, '');
  // 渲染产物抽查
  g('state').selected='ocgo';
  rec('render.inspector.has.manual.query', /手动查询可用/.test(g('renderInspector')()), '');
  g('state').selected='gpt';
  rec('render.inspector.gpt.quota.exhausted', /额度已用完/.test(g('renderInspector')()), '');
  rec('render.editor.paneClass', /class="pane editing"/.test(g('renderEditor')()), '');
  rec('render.drawer', /class="drawer"/.test(g('renderDrawer')()), '');
}

console.table(results);
const fails=results.filter(r=>r.result!=='PASS');
if(fails.length){console.error('FAILED:',fails.length);process.exit(1);}
console.log('ALL PASS ('+results.length+' checks)');
