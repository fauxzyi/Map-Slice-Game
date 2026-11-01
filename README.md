# MapSlice

A browser-based geography game: draw one straight line that splits a country's *population*, not its land, into two equal halves.

Most countries' people are concentrated in a few places, so the line that halves the land is rarely the one that halves the population. To score well, you need to know where people actually live.

## How to play

Each game is 5 rounds, with countries picked at random from a pool of 38.

1. Drag the two dots to position your line, which extends across the whole map.
2. Pan and zoom the map, using the labelled cities, roads and towns as clues.
3. Press **Confirm Split** to see how your line divided the population.

After you confirm, the map shows the two sides in blue and red. A dashed line pivots from your blue dot to show where a true 50/50 split would have been.

### Scoring

Each round is worth up to 100 points, for a maximum of 500 per game:

```
score = 100 − 2 × (percentage points away from a 50/50 split)
```

For example, a 45/55 split scores 90. A split of 0/100 scores 0.

## Running the game

There's nothing to install or build. Clone the repo and open `MapSlice.html` in a browser:

```
git clone https://github.com/fauxzyi/Map-Slice-Game.git
```

You need an internet connection, because Leaflet and the map tiles load from the web.

## Project structure

| Path | Purpose |
| --- | --- |
| `MapSlice.html` | Page layout |
| `styles.css` | Styling |
| `game.js` | Game logic, map setup and scoring |
| `countries-data.js` | Generated country data: borders, cities and population clusters |
| `osm_data/*_fine.json` | Raw country boundaries from OpenStreetMap's Nominatim API |
| `osm_data/process.pl` | Script that generates `countries-data.js` |

## Editing the country data

Country definitions live in the `@countries` list in `osm_data/process.pl`. Change that file rather than editing `countries-data.js` directly, then regenerate the data using Perl:

```
cd osm_data
perl process.pl > ../countries-data.js
```

Run this in Git Bash or a similar shell, because Windows PowerShell's `>` may change the file's encoding.

## About the population data

The population figures are a stylised approximation for gameplay, not census data. Each round scatters random points around weighted clusters, usually centred on major cities, and adds a thin background spread across the country. Your score is based on how those points fall on either side of your line. The points are regenerated each round, so results for the same line can vary slightly.

## Credits

- Map data, country boundaries and city locations: © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright), ODbL 1.0
- Map tile style: [Humanitarian OpenStreetMap Team](https://www.hotosm.org/), hosted by [OpenStreetMap France](https://openstreetmap.fr/)
- Interactive map: [Leaflet](https://leafletjs.com/)
