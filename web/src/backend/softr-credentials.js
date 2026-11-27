'use strict';
const fs=require('node:fs'),path=require('node:path'),{spawnSync}=require('node:child_process');
const ROOT=path.resolve(__dirname,'../..'),SOURCE=path.join(ROOT,'scripts/softr-keychain.swift'),DIR=path.join(ROOT,'.local-credentials'),BINARY=path.join(DIR,'softr-keychain');
const PROMPT='set entered to display dialog "粘贴完整的 Softr API Key。输入将隐藏；验证店铺表成功后才保存到此 Mac 的钥匙串。" default answer "" with hidden answer buttons {"取消", "验证并保存"} default button "验证并保存" cancel button "取消" with title "MallMate · Softr 安全连接"\nreturn text returned of entered';
function create({platform=process.platform,run=spawnSync,files=fs}={}){
 function helper(){
  if(platform!=='darwin')throw Error('Softr Keychain storage requires macOS. Use SOFTR_API_TOKEN on other servers.');
  if(!files.existsSync(BINARY)||files.statSync(SOURCE).mtimeMs>files.statSync(BINARY).mtimeMs){
   files.mkdirSync(DIR,{recursive:true,mode:0o700});
   const result=run('/usr/bin/swiftc',['-O','-module-cache-path',path.join(DIR,'swift-cache'),SOURCE,'-o',BINARY],{encoding:'utf8',timeout:120000,maxBuffer:1024*1024});
   if(result.error||result.status!==0)throw Error('Could not build the local Keychain helper. Install the macOS command line developer tools.');
   files.chmodSync(BINARY,0o700);
  }
  return BINARY;
 }
 function call(command,input){
  const result=run(helper(),[command],{encoding:'utf8',input,timeout:['prompt','notice'].includes(command)?600000:120000,maxBuffer:16384});
  if(result.error)throw Error('The Softr Keychain operation could not finish. Check the macOS permission dialog.');
  return result;
 }
 function read(){
  if(platform!=='darwin')return '';
  const r=call('get');if(r.status===44)return '';
  if(r.status!==0)throw Error('Could not read the Softr Keychain entry. Unlock your login Keychain and try again.');
  return r.stdout.trim();
 }
 function save(value){
  if(typeof value!=='string'||value.trim().length<10||Buffer.byteLength(value.trim())>8192||/[\r\n]/.test(value.trim()))throw Error('Enter a valid Softr API token.');
  const r=call('set',value.trim());
  if(r.status!==0)throw Error('Could not save the Softr key in macOS Keychain. The existing credential was not replaced in memory.');
 }
 function prompt(){
  if(platform!=='darwin')throw Error('Softr secure input requires macOS.');
  const r=run('/usr/bin/osascript',['-e',PROMPT],{encoding:'utf8',timeout:600000,maxBuffer:16384});
  if(r.status===2||(r.stderr||'').includes('(-128)'))return null;
  if(r.error||r.status!==0){
   throw Error(`安全输入窗口未完成（状态 ${r.status??r.signal??'unknown'}）；没有保存密钥。`);
  }
  const value=r.stdout.trim(),length=Buffer.byteLength(value);
  if(value.length<10||length>8192||/[\r\n]/.test(value))throw Error(`未收到有效的完整 Key（收到 ${length} 字节）；没有保存。请在密码输入框中粘贴 Key。`);
  return value;
 }
 function notice(message){call('notice',message);}
 return {read,save,prompt,notice};
}
module.exports={create};
