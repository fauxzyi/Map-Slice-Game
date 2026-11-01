(function(){
"use strict";

// COUNTRY_DEFS is provided by countries-data.js (loaded before this file)

// ---------- Tile source config ----------
// Standard free OpenStreetMap raster tiles (no API key needed).
// To switch to MapTiler's "OMT" (OpenMapTiles) style once you have a free
// API key from maptiler.com, just replace `url` below with e.g.:
//   'https://api.maptiler.com/maps/openstreetmap/{z}/{x}/{y}.png?key=YOUR_KEY'
const TILE_CONFIG = {
  url: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  attribution: '&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a> contributors',
  maxZoom: 18
};

const ROUNDS = 5;

// ---------- Projection helpers ----------
// All line/clipping math is done directly in Leaflet's own Web Mercator
// projected space (the same space it renders straight polyline segments in).
// This guarantees a line we compute as "straight" is rendered exactly where
// we computed it — no mismatch between our math and Leaflet's rendering.
function makeProjector(){
  const crs = map.options.crs;
  return {
    project(lat,lon){ return crs.project(L.latLng(lat,lon)); },
    unproject(pt){ const ll = crs.unproject(L.point(pt.x, pt.y)); return [ll.lat, ll.lng]; },
    // Web Mercator locally scales real ground distance by 1/cos(lat);
    // convert a real-world km radius to projected-space units at this latitude.
    metersPerKmAt(lat){ return 1000 / Math.cos(lat*Math.PI/180); }
  };
}

// ---------- Math helpers (operate in projected xy space) ----------
function pointInPolygon(x,y,poly){
  let inside=false;
  for(let i=0,j=poly.length-1;i<poly.length;j=i++){
    const xi=poly[i][0], yi=poly[i][1], xj=poly[j][0], yj=poly[j][1];
    const intersect = ((yi>y)!==(yj>y)) && (x < (xj-xi)*(y-yi)/(yj-yi)+xi);
    if(intersect) inside=!inside;
  }
  return inside;
}
function pointInRings(x,y,rings){
  for(const ring of rings){ if(pointInPolygon(x,y,ring)) return true; }
  return false;
}
function getBBoxMulti(rings){
  let minX=Infinity,maxX=-Infinity,minY=Infinity,maxY=-Infinity;
  for(const ring of rings){
    for(const [x,y] of ring){
      if(x<minX)minX=x; if(x>maxX)maxX=x;
      if(y<minY)minY=y; if(y>maxY)maxY=y;
    }
  }
  return {minX,maxX,minY,maxY};
}
function randNormal(){
  const u=1-Math.random(), v=Math.random();
  return Math.sqrt(-2*Math.log(u))*Math.cos(2*Math.PI*v);
}
function crossVal(p,A,dir){ return dir.x*(p.y-A.y) - dir.y*(p.x-A.x); }

function generatePoints(country, ringsXY, projector){
  const pts=[];
  for(const c of country.clusters){
    const center = projector.project(c.lat, c.lon);
    const mPerKm = projector.metersPerKmAt(c.lat);
    const sigmaX = mPerKm*c.rxkm/2.2;
    const sigmaY = mPerKm*c.rykm/2.2;
    let count=0, attempts=0;
    const maxAttempts=c.weight*80;
    while(count<c.weight && attempts<maxAttempts){
      attempts++;
      const x=center.x+randNormal()*sigmaX;
      const y=center.y+randNormal()*sigmaY;
      if(pointInRings(x,y,ringsXY)){ pts.push({x,y}); count++; }
    }
    while(count<c.weight){ pts.push({x:center.x,y:center.y}); count++; }
  }
  const bbox=getBBoxMulti(ringsXY);
  const bg=country.background.weight;
  let count=0, attempts=0;
  const maxAttempts=bg*150;
  while(count<bg && attempts<maxAttempts){
    attempts++;
    const x=bbox.minX+Math.random()*(bbox.maxX-bbox.minX);
    const y=bbox.minY+Math.random()*(bbox.maxY-bbox.minY);
    if(pointInRings(x,y,ringsXY)){ pts.push({x,y}); count++; }
  }
  while(count<bg){ pts.push({x:(bbox.minX+bbox.maxX)/2,y:(bbox.minY+bbox.maxY)/2}); count++; }
  return pts;
}

function intersectSeg(prev,curr,A,dir){
  const d1=crossVal(prev,A,dir), d2=crossVal(curr,A,dir);
  const t=d1/(d1-d2);
  return {x:prev.x+t*(curr.x-prev.x), y:prev.y+t*(curr.y-prev.y)};
}
function clipHalf(poly,A,dir,sign){
  const out=[];
  const n=poly.length;
  for(let i=0;i<n;i++){
    const curr={x:poly[i][0],y:poly[i][1]};
    const prev={x:poly[(i-1+n)%n][0],y:poly[(i-1+n)%n][1]};
    const dCurr=crossVal(curr,A,dir)*sign;
    const dPrev=crossVal(prev,A,dir)*sign;
    const currIn=dCurr>=0, prevIn=dPrev>=0;
    if(currIn){
      if(!prevIn) out.push(intersectSeg(prev,curr,A,dir));
      out.push(curr);
    } else if(prevIn){
      out.push(intersectSeg(prev,curr,A,dir));
    }
  }
  return out;
}
function clipHalfMulti(ringsXY, A, dir, sign){
  const out=[];
  for(const ring of ringsXY){
    const clipped = clipHalf(ring, A, dir, sign);
    if(clipped.length>=3) out.push(clipped);
  }
  return out;
}

function findIdealDir(A, points, total){
  let best=null;
  for(let deg=0; deg<180; deg+=0.5){
    const rad=deg*Math.PI/180;
    const dir={x:Math.cos(rad), y:Math.sin(rad)};
    let sumA=0;
    for(const p of points){ if(crossVal(p,A,dir)>=0) sumA++; }
    const pctA = sumA/total*100;
    const dev=Math.abs(50-pctA);
    if(!best||dev<best.dev){ best={dev,dir}; }
  }
  return best.dir;
}

const FAR_METERS = 4000000; // Web Mercator projected units; long enough to span any single country at any zoom

// Web Mercator's projection clamps latitude to ~85.0511 deg (y = ±20,037,508.34).
// If we ask Leaflet to render a point beyond that, it silently pulls the point
// back to the clamp boundary — which, over a multi-million-metre extension,
// swings the *whole rendered line* away from the true line by many kilometres.
// So we clamp our own extension distance per-direction to stay safely inside
// that bound, guaranteeing the point we hand Leaflet round-trips exactly.
const MAX_MERCATOR_Y = 20037508.34 * 0.97;
function extendAlong(A, dir, dist){
  let t = dist;
  const targetY = A.y + dir.y*t;
  if(Math.abs(targetY) > MAX_MERCATOR_Y && dir.y !== 0){
    const room = Math.sign(dir.y)*MAX_MERCATOR_Y - A.y;
    t = Math.max(0, Math.min(t, room/dir.y));
  }
  return {x:A.x+dir.x*t, y:A.y+dir.y*t};
}

function shuffle(arr){
  const a = arr.slice();
  for(let i=a.length-1;i>0;i--){
    const j = Math.floor(Math.random()*(i+1));
    [a[i],a[j]]=[a[j],a[i]];
  }
  return a;
}
function pickRandomCountries(pool, n){
  return shuffle(pool).slice(0, n);
}

// ---------- Leaflet map setup ----------
const map = L.map('mapDiv', { attributionControl: true });
L.tileLayer(TILE_CONFIG.url, {
  maxZoom: TILE_CONFIG.maxZoom,
  attribution: TILE_CONFIG.attribution
}).addTo(map);
map.setView([20,0], 2);

let roundLayer = L.layerGroup().addTo(map);

// ---------- Game state ----------
let order = [];
let roundIdx = 0;
let scores = [];
let currentCountry = null;
let currentRingsXY = null;
let currentProjector = null;
let currentPoints = null;
let handleALatLng = null;
let handleBLatLng = null;
let handleMarkerA = null;
let handleMarkerB = null;
let solidLine = null;
let idealLine = null;
let confirmed = false;

function makeHandleIcon(cls){
  return L.divIcon({ className: 'handle-icon ' + cls, iconSize:[22,22], iconAnchor:[11,11] });
}

function startGame(){
  order = pickRandomCountries(COUNTRY_DEFS, ROUNDS);
  roundIdx = 0;
  scores = [];
  document.getElementById('finalOverlay').classList.remove('show');
  updateTotals();
  renderScoreboard();
  loadRound();
}

function loadRound(){
  confirmed = false;
  currentCountry = order[roundIdx];
  currentRingsXY = null;
  currentProjector = makeProjector();
  currentRingsXY = currentCountry.polygon.map(ring => ring.map(([lat,lon]) => {
    const p = currentProjector.project(lat,lon);
    return [p.x, p.y];
  }));
  currentPoints = generatePoints(currentCountry, currentRingsXY, currentProjector);

  document.getElementById('roundNum').textContent = roundIdx+1;
  document.getElementById('countryName').textContent = currentCountry.name;
  document.getElementById('resultPanel').classList.remove('show');
  document.getElementById('confirmBtn').style.display='';
  document.getElementById('confirmBtn').disabled=false;
  document.getElementById('resetBtn').style.display='';
  document.getElementById('nextBtn').style.display='none';

  roundLayer.clearLayers();

  const bounds = L.latLngBounds([]);
  for(const ring of currentCountry.polygon){ for(const pt of ring){ bounds.extend(pt); } }

  // Dim the rest of the world by drawing a world-covering rectangle with
  // each country ring cut out as a hole, so only the target country stays clear.
  const WORLD_RECT = [[-85,-179.9],[85,-179.9],[85,179.9],[-85,179.9]];
  L.polygon([WORLD_RECT, ...currentCountry.polygon], {
    stroke:false, fillColor:'#0a1424', fillOpacity:0.55, interactive:false
  }).addTo(roundLayer);

  currentCountry.polygon.forEach((ring, i) => {
    const weight = i===0 ? 3 : 1.5;
    L.polygon(ring, { color:'#ffcc33', weight, fillColor:'#ffcc33', fillOpacity:0.06 }).addTo(roundLayer);
  });
  map.fitBounds(bounds, { padding:[30,30] });

  for(const city of currentCountry.cities){
    L.circleMarker([city.lat, city.lon], {
      radius:5, color:'#20242c', weight:2, fillColor:'#ffffff', fillOpacity:1
    }).bindTooltip(city.name, { permanent:true, direction:'right', offset:[8,0], className:'city-label' })
      .addTo(roundLayer);
  }

  const north = bounds.getNorth(), south = bounds.getSouth();
  const centerLng = bounds.getCenter().lng;
  const span = north - south;
  handleALatLng = L.latLng(north - span*0.15, centerLng);
  handleBLatLng = L.latLng(south + span*0.15, centerLng);

  handleMarkerA = L.marker(handleALatLng, { draggable:true, icon: makeHandleIcon('handle-a') }).addTo(roundLayer);
  handleMarkerB = L.marker(handleBLatLng, { draggable:true, icon: makeHandleIcon('handle-b') }).addTo(roundLayer);

  solidLine = L.polyline([handleALatLng, handleBLatLng], { className:'solid-line' }).addTo(roundLayer);
  idealLine = null;

  handleMarkerA.on('drag', ()=>{ handleALatLng = handleMarkerA.getLatLng(); updateLineVisual(); });
  handleMarkerB.on('drag', ()=>{ handleBLatLng = handleMarkerB.getLatLng(); updateLineVisual(); });

  updateLineVisual();
}

function updateLineVisual(){
  const A = currentProjector.project(handleALatLng.lat, handleALatLng.lng);
  const B = currentProjector.project(handleBLatLng.lat, handleBLatLng.lng);
  const dx=B.x-A.x, dy=B.y-A.y;
  const len=Math.hypot(dx,dy) || 1;
  const dir={x:dx/len, y:dy/len};
  // Extend well beyond both handles, however far apart they are.
  const reach = Math.max(FAR_METERS, len*3);
  const far1 = currentProjector.unproject(extendAlong(A, dir, reach));
  const far2 = currentProjector.unproject(extendAlong(A, {x:-dir.x,y:-dir.y}, reach));
  solidLine.setLatLngs([far1, far2]);
}

function confirmSplit(){
  updateLineVisual();
  const A = currentProjector.project(handleALatLng.lat, handleALatLng.lng);
  const B = currentProjector.project(handleBLatLng.lat, handleBLatLng.lng);
  const dx=B.x-A.x, dy=B.y-A.y;
  const len=Math.hypot(dx,dy);
  if(len < 5000){
    alert('Please drag the two points further apart to define a clear line.');
    return;
  }
  confirmed = true;
  const dir={x:dx/len, y:dy/len};
  const total = currentPoints.length;

  let sumA=0;
  for(const p of currentPoints){ if(crossVal(p,A,dir)>=0) sumA++; }
  const pctA = sumA/total*100;
  const pctB = 100-pctA;
  const deviation = Math.abs(50-pctA);
  const roundScore = Math.max(0, Math.round(100 - deviation*2));

  scores.push({country:currentCountry.name, score:roundScore, pctA:pctA, pctB:pctB});

  const regA = clipHalfMulti(currentRingsXY, A, dir, 1);
  const regB = clipHalfMulti(currentRingsXY, A, dir, -1);
  for(const ring of regA){
    const latlngs = ring.map(pt => currentProjector.unproject(pt));
    L.polygon(latlngs, { className:'region-a', stroke:false, fillOpacity:1 }).addTo(roundLayer);
  }
  for(const ring of regB){
    const latlngs = ring.map(pt => currentProjector.unproject(pt));
    L.polygon(latlngs, { className:'region-b', stroke:false, fillOpacity:1 }).addTo(roundLayer);
  }

  const idealDir = findIdealDir(A, currentPoints, total);
  const reach = Math.max(FAR_METERS, len*3);
  const idealFar1 = currentProjector.unproject(extendAlong(A, idealDir, reach));
  const idealFar2 = currentProjector.unproject(extendAlong(A, {x:-idealDir.x,y:-idealDir.y}, reach));
  idealLine = L.polyline([idealFar1, idealFar2], { className:'ideal-line' }).addTo(roundLayer);

  handleMarkerA.dragging.disable();
  handleMarkerB.dragging.disable();

  document.getElementById('pctA').textContent = pctA.toFixed(1)+'%';
  document.getElementById('pctB').textContent = pctB.toFixed(1)+'%';
  document.getElementById('barA').style.width = pctA+'%';
  document.getElementById('barB').style.width = pctB+'%';
  document.getElementById('roundScore').textContent = roundScore;
  document.getElementById('resultPanel').classList.add('show');
  document.getElementById('confirmBtn').disabled=true;
  document.getElementById('resetBtn').style.display='none';
  document.getElementById('nextBtn').style.display='';
  document.getElementById('nextBtn').textContent = (roundIdx===ROUNDS-1) ? 'See Final Score' : 'Next Round';

  updateTotals();
  renderScoreboard();
}

function updateTotals(){
  const total = scores.reduce((s,r)=>s+r.score,0);
  document.getElementById('totalScore').textContent = total;
  document.getElementById('totalMax').textContent = ROUNDS*100;
}

function renderScoreboard(){
  const list = document.getElementById('scoreList');
  list.innerHTML='';
  for(let i=0;i<ROUNDS;i++){
    const li = document.createElement('li');
    if(scores[i]){
      li.innerHTML = `Round ${i+1}: ${scores[i].country}<br><b>${scores[i].score}</b> / 100`;
    } else {
      li.innerHTML = `Round ${i+1}: —`;
      li.style.opacity='0.5';
    }
    list.appendChild(li);
  }
}

function nextRound(){
  if(roundIdx === ROUNDS-1){
    showFinal();
    return;
  }
  roundIdx++;
  loadRound();
}

function showFinal(){
  const total = scores.reduce((s,r)=>s+r.score,0);
  document.getElementById('finalScoreText').textContent = `${total} / ${ROUNDS*100}`;
  const list = document.getElementById('finalList');
  list.innerHTML='';
  scores.forEach((r,i)=>{
    const li = document.createElement('li');
    li.innerHTML = `<span>Round ${i+1} — ${r.country}</span><span><b>${r.score}</b>/100</span>`;
    list.appendChild(li);
  });
  document.getElementById('finalOverlay').classList.add('show');
}

document.getElementById('confirmBtn').addEventListener('click', confirmSplit);
document.getElementById('resetBtn').addEventListener('click', ()=>{
  if(confirmed) return;
  const bounds = L.latLngBounds([]);
  for(const ring of currentCountry.polygon){ for(const pt of ring){ bounds.extend(pt); } }
  const north = bounds.getNorth(), south = bounds.getSouth();
  const centerLng = bounds.getCenter().lng;
  const span = north - south;
  handleALatLng = L.latLng(north - span*0.15, centerLng);
  handleBLatLng = L.latLng(south + span*0.15, centerLng);
  handleMarkerA.setLatLng(handleALatLng);
  handleMarkerB.setLatLng(handleBLatLng);
  updateLineVisual();
});
document.getElementById('nextBtn').addEventListener('click', nextRound);
document.getElementById('playAgainBtn').addEventListener('click', startGame);

startGame();
})();
