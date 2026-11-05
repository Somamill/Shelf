const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync('Resources/Dashboard/app.js','utf8');
const code=source.slice(source.indexOf('function renderStatistics(){'),source.indexOf('\nfunction action('));
test('statistics survive missing sources and invalid event dates, and do not label every Hardcover book as audio',()=>{
 const nodes=new Map(),document={getElementById:id=>{if(!nodes.has(id))nodes.set(id,{});return nodes.get(id)}};
 const context={document,booksData:null,data:{syncActivity:[{date:'broken-date'}],connectors:null},unifiedBooks:()=>[
  {title:'Ebook',formats:'EPUB',progress:.2,hardcover:{}},
  {title:'Audio',mediaType:'audiobook',progress:.5},
  {title:'Finished',formats:'PDF',progress:1},
  {title:'Unstarted external document',appleBooks:{}},
  {title:'Unstarted audio catalog entry',mediaType:'audiobook'}
 ],esc:String,badge:String};
 vm.createContext(context);vm.runInContext(code+';renderStatistics()',context);
 assert.equal(nodes.get('statsTrackedBooks').textContent,'3');
 assert.match(nodes.get('readingStatsCards').innerHTML,/AUDIOBOOKS<\/span><strong>1<\/strong>/);
 assert.match(nodes.get('readingActivity').innerHTML,/No sync activity/);
 context.data={syncActivity:'unavailable',connectors:[]};
 assert.doesNotThrow(()=>vm.runInContext('renderStatistics()',context));
});
