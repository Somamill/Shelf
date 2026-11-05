const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync('Sources/ShelfMacApp/AppMain.swift','utf8');
const code=source.slice(source.indexOf('function layoutPages(){'),source.indexOf('\n              function chapterIndex()'));
test('font/layout changes preserve saved progress instead of an obsolete page number',()=>{
 const context={readerViewport:{scrollLeft:0},readerFlow:{style:{},scrollWidth:730*1000},step:()=>1000,pageCount:200,currentPage:8,userHasNavigated:false,window:{readerBook:{resumePercentage:.0382}}};
 vm.createContext(context);vm.runInContext(code+';layoutPages()',context);
 assert.equal(context.pageCount,730);assert.equal(context.currentPage,28);assert.equal(context.readerViewport.scrollLeft,28000);
 context.userHasNavigated=true;context.currentPage=29;context.readerFlow.scrollWidth=1000*1000;
 vm.runInContext('layoutPages()',context);
 assert.equal(context.currentPage,Math.round(29/729*999));
});
test('restoring a page is immediate; only user page turns animate',()=>{
 const start=source.indexOf('function setPage(page,userAction){'),end=source.indexOf('\n',start);
 const context={readerViewport:{scrollTo:options=>context.lastScroll=options},layoutPages:()=>{},pageCount:730,currentPage:0,step:()=>1000,window:{setTimeout:()=>{}},sendPosition:()=>{}};
 vm.createContext(context);vm.runInContext(source.slice(start,end)+';setPage(28,false)',context);
 assert.equal(context.lastScroll.behavior,'instant');assert.equal(context.lastScroll.left,28000);
 vm.runInContext('setPage(29,true)',context);assert.equal(context.lastScroll.behavior,'smooth');assert.equal(context.userHasNavigated,true);
});
