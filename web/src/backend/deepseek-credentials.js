'use strict';
const fs=require('node:fs'),path=require('node:path'),{spawnSync}=require('node:child_process');
const ROOT=path.resolve(__dirname,'../..'),DIR=path.join(ROOT,'.local-credentials'),SOURCE=path.join(ROOT,'scripts/deepseek-keychain.swift'),BINARY=path.join(DIR,'deepseek-keychain');
const PROMPT='set entered to display dialog "粘贴 DeepSeek API Key（输入隐藏）。如果是课程提供的 Key，点击「课程网关」；自己的 DeepSeek Key 点击「官方 DeepSeek」。验证成功后才保存到本机钥匙串。" default answer "" with hidden answer buttons {"取消", "课程网关", "官方 DeepSeek"} default button "官方 DeepSeek" cancel button "取消" with title "MallMate · DeepSeek 安全配置"\nreturn (button returned of entered) & linefeed & (text returned of entered)';
function validate(value){if(!value||!['course','official'].includes(value.provider)||typeof value.key!=='string'||value.key.length<10||Buffer.byteLength(value.key)>8192||/\s/.test(value.key))throw Error('没有收到有效的完整 Key；没有保存。');return value;}
function create({run=spawnSync,files=fs,platform=process.platform}={}){
 function helper(){
  if(platform!=='darwin')throw Error('系统钥匙串需要 macOS；服务器可以使用环境变量配置。');
  if(!files.existsSync(BINARY)||files.statSync(SOURCE).mtimeMs>files.statSync(BINARY).mtimeMs){
   files.mkdirSync(DIR,{recursive:true,mode:0o700});const r=run('/usr/bin/swiftc',['-O','-module-cache-path',path.join(DIR,'swift-cache'),SOURCE,'-o',BINARY],{encoding:'utf8',timeout:120000,maxBuffer:1048576});
   if(r.error||r.status!==0)throw Error('无法构建本地钥匙串辅助程序。');files.chmodSync(BINARY,0o700);
  }return BINARY;
 }
 function read(){if(platform!=='darwin')return null;const r=run(helper(),['get'],{encoding:'utf8',timeout:120000,maxBuffer:16384});if(r.status===44)return null;if(r.error||r.status!==0)throw Error('无法读取 DeepSeek 钥匙串项目；请检查系统访问提示。');try{return validate(JSON.parse(r.stdout));}catch{throw Error('DeepSeek 钥匙串项目格式异常。');}}
 function save(value){validate(value);const r=run(helper(),['set'],{encoding:'utf8',input:JSON.stringify(value),timeout:120000,maxBuffer:16384});if(r.error||r.status!==0)throw Error('无法保存到系统钥匙串。');}
 function prompt(){const r=run('/usr/bin/osascript',['-e',PROMPT],{encoding:'utf8',timeout:600000,maxBuffer:16384});if((r.stderr||'').includes('(-128)'))return null;if(r.error||r.status!==0)throw Error('安全输入窗口未完成；没有保存。');const [label,...parts]=r.stdout.trim().split('\n');return validate({provider:label==='课程网关'?'course':'official',key:parts.join('\n').trim()});}
 function notice(message){const script='display dialog '+JSON.stringify(message)+' buttons {"知道了"} default button "知道了" with title "MallMate · DeepSeek 配置结果"';run('/usr/bin/osascript',['-e',script],{encoding:'utf8',timeout:600000,maxBuffer:1024});}
 return {read,save,prompt,notice};
}
module.exports={create,validate};
