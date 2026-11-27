'use strict';

const path=require('node:path');
const port=process.env.MALLMATE_PORT||'8766';
Object.assign(process.env,{
  MALLMATE_PORT:port,
  MALLMATE_REVIEW_LOCAL:'1',
  MALLMATE_PUBLIC_ORIGIN:'http://127.0.0.1:'+port,
  MALLMATE_DATA_DIR:path.resolve(process.env.MALLMATE_DATA_DIR||'.review-data')
});
require('./web/server.js');
