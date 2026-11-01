#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP;

my $json = JSON::PP->new;

sub shoelace {
    my ($ring) = @_;
    my $sum = 0;
    my $n = scalar(@$ring);
    for my $i (0..$n-1) {
        my $j = ($i+1) % $n;
        my ($x1,$y1) = @{$ring->[$i]};
        my ($x2,$y2) = @{$ring->[$j]};
        $sum += $x1*$y2 - $x2*$y1;
    }
    return abs($sum)/2;
}
sub clean_ring {
    my ($ring) = @_;
    my @pts = @$ring;
    if (@pts > 1 && $pts[0][0] == $pts[-1][0] && $pts[0][1] == $pts[-1][1]) { pop @pts; }
    return \@pts;
}
sub load_all_rings {
    my ($file) = @_;
    open(my $fh, "<", $file) or die "cannot open $file: $!";
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $data = $json->decode($raw);
    my $geo = $data->[0]{geojson};
    my @rings;
    if ($geo->{type} eq 'MultiPolygon') {
        @rings = map { clean_ring($_->[0]) } @{$geo->{coordinates}};
    } else {
        @rings = (clean_ring($geo->{coordinates}[0]));
    }
    return \@rings;
}
sub sample_pts {
    my ($ring, $maxN) = @_;
    my $n = scalar(@$ring);
    return $ring if $n <= $maxN;
    my $step = $n / $maxN;
    my @out;
    for (my $i = 0; $i < $n; $i += $step) { push @out, $ring->[int($i)]; }
    return \@out;
}
sub min_dist_km {
    my ($ringA, $ringB) = @_;
    my $sa = sample_pts($ringA, 400);
    my $sb = sample_pts($ringB, 200);
    my $best = 9e18;
    for my $a (@$sa) {
        my ($ax,$ay) = @$a;
        for my $b (@$sb) {
            my $dx = $ax-$b->[0]; my $dy=$ay-$b->[1];
            my $d2 = $dx*$dx+$dy*$dy;
            $best = $d2 if $d2 < $best;
        }
    }
    return sqrt($best) * 111;
}
# Real-world approximate area in km^2 (accounts for longitude compression at
# this ring's latitude). A relative %-of-mainland threshold doesn't work: a
# genuinely large island (e.g. Hainan) is still a tiny % of giant China, while
# a real speck is a similar tiny % of a small country. Absolute size is what
# actually distinguishes "a real island worth showing" from "a reef speck".
sub area_km2 {
    my ($ring, $areaDeg2) = @_;
    my ($sumLat, $n) = (0, 0);
    for my $p (@$ring) { $sumLat += $p->[1]; $n++; }
    my $meanLat = $sumLat / $n;
    return $areaDeg2 * 12321 * cos($meanLat * 3.14159265358979 / 180);
}

# Select the main ring, and (only if explicitly requested per-country) any
# "nearby" secondary rings. Many countries' OSM relations mix in member ways
# for marine parks / EEZ / wildlife-refuge administrative boundaries alongside
# the real coastline — these look like blobs of open ocean when rendered, not
# islands. We only enable multi-ring for countries whose secondary rings were
# individually checked against real map tiles and confirmed to be real land.
sub select_rings {
    my ($file, %opt) = @_;
    my $rings = load_all_rings($file);
    my @withArea = map { { ring=>$_, area=>shoelace($_) } } @$rings;
    @withArea = sort { $b->{area} <=> $a->{area} } @withArea;
    my $main = $withArea[0];
    my @keep = ($main->{ring});
    return \@keep unless $opt{multi};

    my $gapKm = $opt{gapKm} // 300;
    my $minKm2 = $opt{minKm2} // 300; # roughly "an island you'd see named on an atlas"
    for my $i (1..$#withArea) {
        my $r = $withArea[$i];
        next if area_km2($r->{ring}, $r->{area}) < $minKm2;
        my $dist = min_dist_km($main->{ring}, $r->{ring});
        next if $dist > $gapKm;
        push @keep, $r->{ring};
    }
    return \@keep;
}

sub round4 { return sprintf("%.4f", $_[0]); }
sub jsq {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/'/\\'/g;
    return $s;
}

sub emit_country {
    my (%c) = @_;
    my $rings;
    if ($c{rings}) {
        # explicit pre-selected rings (used for UK: GB + NI fetched separately)
        $rings = $c{rings};
    } else {
        $rings = select_rings($c{file}, multi=>$c{multi}, gapKm=>$c{gapKm}, minKm2=>$c{minKm2});
    }

    my $maxPts = 600;
    print "  {\n";
    print "    id:'" . jsq($c{id}) . "', name:'" . jsq($c{name}) . "',\n";
    print "    polygon:[\n";
    for my $ring (@$rings) {
        my @pts = @$ring;
        my $step = 1;
        if (@pts > $maxPts) { $step = int(@pts / $maxPts) + 1; }
        print "      [";
        my $first = 1;
        for (my $i = 0; $i < @pts; $i += $step) {
            my ($lon,$lat) = @{$pts[$i]};
            print "," unless $first;
            $first = 0;
            print "[" . round4($lat) . "," . round4($lon) . "]";
        }
        print "],\n";
    }
    print "    ],\n";

    print "    cities:[\n";
    for my $city (@{$c{cities}}) {
        print "      {name:'" . jsq($city->{name}) . "', lat:$city->{lat}, lon:$city->{lon}},\n";
    }
    print "    ],\n";

    print "    clusters:[\n";
    for my $cl (@{$c{clusters}}) {
        print "      {lat:$cl->{lat},lon:$cl->{lon},rxkm:$cl->{rxkm},rykm:$cl->{rykm},weight:$cl->{weight}},\n";
    }
    print "    ],\n";
    print "    background:{weight:$c{bgweight}}\n";
    print "  }";
}

# ---- UK: fetch GB island + Northern Ireland separately (their merged
# "United Kingdom" relation traces a distorted line between them) ----
my $gb_rings = load_all_rings('gb_fine.json');
my @gb_by_area = sort { shoelace($b) <=> shoelace($a) } @$gb_rings;
my $gb_main = $gb_by_area[0];
my $ni_rings = load_all_rings('ni_fine.json');
my @ni_by_area = sort { shoelace($b) <=> shoelace($a) } @$ni_rings;
my $ni_main = $ni_by_area[0];
my $uk_rings = [$gb_main, $ni_main];

my @countries = (
  {
    file=>'usa_fine.json', id=>'usa', name=>'United States',
    cities=>[
      {name=>'New York', lat=>40.7128, lon=>-74.0060},
      {name=>'Los Angeles', lat=>34.0522, lon=>-118.2437},
      {name=>'Chicago', lat=>41.8781, lon=>-87.6298},
      {name=>'Houston', lat=>29.7604, lon=>-95.3698},
      {name=>'Miami', lat=>25.7617, lon=>-80.1918},
      {name=>'Seattle', lat=>47.6062, lon=>-122.3321},
      {name=>'Atlanta', lat=>33.7490, lon=>-84.3880},
      {name=>'Dallas', lat=>32.7767, lon=>-96.7970},
    ],
    clusters=>[
      {lat=>40.7,lon=>-74.5,rxkm=>180,rykm=>350,weight=>220},
      {lat=>41.88,lon=>-87.63,rxkm=>220,rykm=>180,weight=>120},
      {lat=>34.5,lon=>-119.5,rxkm=>150,rykm=>450,weight=>180},
      {lat=>30.5,lon=>-97.0,rxkm=>220,rykm=>220,weight=>130},
      {lat=>25.76,lon=>-80.19,rxkm=>120,rykm=>220,weight=>90},
      {lat=>47.6,lon=>-122.3,rxkm=>100,rykm=>130,weight=>40},
      {lat=>33.75,lon=>-84.39,rxkm=>180,rykm=>180,weight=>70},
    ],
    bgweight=>150,
  },
  {
    file=>'brazil_fine.json', id=>'brazil', name=>'Brazil',
    cities=>[
      {name=>'São Paulo', lat=>-23.5505, lon=>-46.6333},
      {name=>'Rio de Janeiro', lat=>-22.9068, lon=>-43.1729},
      {name=>'Salvador', lat=>-12.9777, lon=>-38.5016},
      {name=>'Recife', lat=>-8.0476, lon=>-34.8770},
      {name=>'Fortaleza', lat=>-3.7172, lon=>-38.5433},
      {name=>'Brasília', lat=>-15.8267, lon=>-47.9218},
      {name=>'Manaus', lat=>-3.1190, lon=>-60.0217},
    ],
    clusters=>[
      {lat=>-23.2,lon=>-45.5,rxkm=>150,rykm=>250,weight=>380},
      {lat=>-8.0,lon=>-37.0,rxkm=>200,rykm=>350,weight=>220},
      {lat=>-27.0,lon=>-50.0,rxkm=>200,rykm=>200,weight=>120},
      {lat=>-15.83,lon=>-47.92,rxkm=>150,rykm=>150,weight=>40},
      {lat=>-3.12,lon=>-60.02,rxkm=>150,rykm=>150,weight=>30},
    ],
    bgweight=>210,
  },
  {
    file=>'australia_fine.json', id=>'australia', name=>'Australia',
    cities=>[
      {name=>'Sydney', lat=>-33.8688, lon=>151.2093},
      {name=>'Melbourne', lat=>-37.8136, lon=>144.9631},
      {name=>'Brisbane', lat=>-27.4698, lon=>153.0251},
      {name=>'Perth', lat=>-31.9505, lon=>115.8605},
      {name=>'Adelaide', lat=>-34.9285, lon=>138.6007},
      {name=>'Darwin', lat=>-12.4634, lon=>130.8456},
      {name=>'Hobart', lat=>-42.8821, lon=>147.3272},
    ],
    clusters=>[
      {lat=>-33.87,lon=>151.21,rxkm=>120,rykm=>120,weight=>250},
      {lat=>-37.81,lon=>144.96,rxkm=>130,rykm=>110,weight=>210},
      {lat=>-27.47,lon=>153.03,rxkm=>120,rykm=>120,weight=>130},
      {lat=>-31.95,lon=>115.86,rxkm=>130,rykm=>150,weight=>110},
      {lat=>-34.93,lon=>138.60,rxkm=>100,rykm=>90,weight=>70},
      {lat=>-12.46,lon=>130.85,rxkm=>90,rykm=>80,weight=>20},
      {lat=>-42.88,lon=>147.33,rxkm=>70,rykm=>70,weight=>30},
    ],
    bgweight=>180,
  },
  {
    file=>'egypt_fine.json', id=>'egypt', name=>'Egypt',
    cities=>[
      {name=>'Cairo', lat=>30.0444, lon=>31.2357},
      {name=>'Alexandria', lat=>31.2001, lon=>29.9187},
      {name=>'Port Said', lat=>31.2653, lon=>32.3019},
      {name=>'Luxor', lat=>25.6872, lon=>32.6396},
      {name=>'Aswan', lat=>24.0889, lon=>32.8998},
    ],
    clusters=>[
      {lat=>30.6,lon=>31.0,rxkm=>200,rykm=>140,weight=>700},
      {lat=>28.1,lon=>30.75,rxkm=>60,rykm=>140,weight=>80},
      {lat=>27.2,lon=>31.17,rxkm=>55,rykm=>140,weight=>70},
      {lat=>26.2,lon=>32.0,rxkm=>50,rykm=>140,weight=>60},
      {lat=>24.9,lon=>32.75,rxkm=>45,rykm=>130,weight=>50},
    ],
    bgweight=>40,
  },
  {
    file=>'india_fine.json', id=>'india', name=>'India',
    cities=>[
      {name=>'Delhi', lat=>28.7041, lon=>77.1025},
      {name=>'Patna', lat=>25.5941, lon=>85.1376},
      {name=>'Kolkata', lat=>22.5726, lon=>88.3639},
      {name=>'Mumbai', lat=>19.0760, lon=>72.8777},
      {name=>'Hyderabad', lat=>17.3850, lon=>78.4867},
      {name=>'Bangalore', lat=>12.9716, lon=>77.5946},
      {name=>'Chennai', lat=>13.0827, lon=>80.2707},
      {name=>'Kochi', lat=>9.9312, lon=>76.2673},
    ],
    clusters=>[
      {lat=>28.70,lon=>77.10,rxkm=>150,rykm=>130,weight=>130},
      {lat=>26.5,lon=>82.5,rxkm=>250,rykm=>130,weight=>120},
      {lat=>22.57,lon=>88.36,rxkm=>150,rykm=>150,weight=>130},
      {lat=>19.08,lon=>72.88,rxkm=>140,rykm=>160,weight=>110},
      {lat=>13.08,lon=>80.27,rxkm=>140,rykm=>150,weight=>90},
      {lat=>15.2,lon=>78.0,rxkm=>200,rykm=>220,weight=>100},
      {lat=>9.93,lon=>76.27,rxkm=>120,rykm=>150,weight=>40},
    ],
    bgweight=>280,
  },
  {
    file=>'china_fine.json', id=>'china', name=>'China',
    cities=>[
      {name=>'Beijing', lat=>39.9042, lon=>116.4074},
      {name=>'Shanghai', lat=>31.2304, lon=>121.4737},
      {name=>'Guangzhou', lat=>23.1291, lon=>113.2644},
      {name=>'Chengdu', lat=>30.5728, lon=>104.0668},
      {name=>"Xi'an", lat=>34.3416, lon=>108.9398},
      {name=>'Urumqi', lat=>43.8256, lon=>87.6168},
      {name=>'Haikou', lat=>20.0440, lon=>110.1920},
    ],
    clusters=>[
      {lat=>39.5,lon=>117.0,rxkm=>250,rykm=>200,weight=>150},
      {lat=>31.2,lon=>121.3,rxkm=>200,rykm=>200,weight=>200},
      {lat=>22.8,lon=>113.8,rxkm=>150,rykm=>150,weight=>180},
      {lat=>30.0,lon=>105.5,rxkm=>200,rykm=>180,weight=>140},
      {lat=>31.5,lon=>113.0,rxkm=>300,rykm=>200,weight=>130},
      {lat=>34.3,lon=>109.0,rxkm=>150,rykm=>130,weight=>50},
      {lat=>20.0,lon=>110.2,rxkm=>60,rykm=>60,weight=>10},
    ],
    bgweight=>140,
  },
  {
    rings=>$uk_rings, id=>'uk', name=>'United Kingdom',
    cities=>[
      {name=>'London', lat=>51.5074, lon=>-0.1278},
      {name=>'Manchester', lat=>53.4808, lon=>-2.2426},
      {name=>'Birmingham', lat=>52.4862, lon=>-1.8904},
      {name=>'Glasgow', lat=>55.8642, lon=>-4.2518},
      {name=>'Leeds', lat=>53.8008, lon=>-1.5491},
      {name=>'Edinburgh', lat=>55.9533, lon=>-3.1883},
      {name=>'Belfast', lat=>54.5973, lon=>-5.9301},
    ],
    clusters=>[
      {lat=>51.5,lon=>-0.2,rxkm=>90,rykm=>90,weight=>290},
      {lat=>52.48,lon=>-1.9,rxkm=>90,rykm=>80,weight=>145},
      {lat=>53.6,lon=>-1.9,rxkm=>100,rykm=>90,weight=>195},
      {lat=>55.9,lon=>-3.7,rxkm=>100,rykm=>80,weight=>115},
      {lat=>54.6,lon=>-5.93,rxkm=>50,rykm=>50,weight=>35},
    ],
    bgweight=>220,
  },
  {
    file=>'canada_fine.json', id=>'canada', name=>'Canada',
    cities=>[
      {name=>'Toronto', lat=>43.6532, lon=>-79.3832},
      {name=>'Montreal', lat=>45.5017, lon=>-73.5673},
      {name=>'Vancouver', lat=>49.2827, lon=>-123.1207},
      {name=>'Calgary', lat=>51.0447, lon=>-114.0719},
      {name=>'Ottawa', lat=>45.4215, lon=>-75.6972},
      {name=>'Winnipeg', lat=>49.8951, lon=>-97.1384},
    ],
    clusters=>[
      {lat=>43.7,lon=>-79.4,rxkm=>100,rykm=>100,weight=>260},
      {lat=>45.5,lon=>-73.6,rxkm=>100,rykm=>100,weight=>170},
      {lat=>49.2,lon=>-123.1,rxkm=>90,rykm=>90,weight=>130},
      {lat=>51.0,lon=>-114.0,rxkm=>100,rykm=>90,weight=>90},
      {lat=>45.4,lon=>-75.7,rxkm=>70,rykm=>70,weight=>50},
    ],
    bgweight=>300,
  },
  {
    file=>'mexico_fine.json', id=>'mexico', name=>'Mexico',
    cities=>[
      {name=>'Mexico City', lat=>19.4326, lon=>-99.1332},
      {name=>'Guadalajara', lat=>20.6597, lon=>-103.3496},
      {name=>'Monterrey', lat=>25.6866, lon=>-100.3161},
      {name=>'Puebla', lat=>19.0414, lon=>-98.2063},
      {name=>'Tijuana', lat=>32.5149, lon=>-117.0382},
      {name=>'Cancún', lat=>21.1619, lon=>-86.8515},
    ],
    clusters=>[
      {lat=>19.4,lon=>-99.1,rxkm=>100,rykm=>100,weight=>280},
      {lat=>20.66,lon=>-103.35,rxkm=>90,rykm=>90,weight=>130},
      {lat=>25.69,lon=>-100.32,rxkm=>90,rykm=>90,weight=>110},
      {lat=>19.04,lon=>-98.2,rxkm=>90,rykm=>90,weight=>90},
      {lat=>32.51,lon=>-117.04,rxkm=>60,rykm=>60,weight=>60},
    ],
    bgweight=>330,
  },
  {
    file=>'nigeria_fine.json', id=>'nigeria', name=>'Nigeria',
    cities=>[
      {name=>'Lagos', lat=>6.5244, lon=>3.3792},
      {name=>'Kano', lat=>12.0022, lon=>8.5920},
      {name=>'Ibadan', lat=>7.3775, lon=>3.9470},
      {name=>'Abuja', lat=>9.0765, lon=>7.3986},
      {name=>'Port Harcourt', lat=>4.8156, lon=>7.0498},
      {name=>'Kaduna', lat=>10.5222, lon=>7.4383},
    ],
    clusters=>[
      {lat=>6.52,lon=>3.38,rxkm=>70,rykm=>70,weight=>220},
      {lat=>7.38,lon=>3.95,rxkm=>90,rykm=>90,weight=>130},
      {lat=>12.0,lon=>8.6,rxkm=>100,rykm=>90,weight=>150},
      {lat=>9.08,lon=>7.40,rxkm=>80,rykm=>80,weight=>80},
      {lat=>4.82,lon=>7.05,rxkm=>80,rykm=>80,weight=>110},
      {lat=>10.52,lon=>7.44,rxkm=>90,rykm=>80,weight=>90},
    ],
    bgweight=>220,
  },
  {
    file=>'japan_fine.json', id=>'japan', name=>'Japan', multi=>1, gapKm=>300, minKm2=>50,
    cities=>[
      {name=>'Tokyo', lat=>35.6762, lon=>139.6503},
      {name=>'Osaka', lat=>34.6937, lon=>135.5023},
      {name=>'Nagoya', lat=>35.1815, lon=>136.9066},
      {name=>'Fukuoka', lat=>33.5904, lon=>130.4017},
      {name=>'Sapporo', lat=>43.0618, lon=>141.3545},
      {name=>'Sendai', lat=>38.2682, lon=>140.8694},
      {name=>'Naha', lat=>26.2124, lon=>127.6809},
    ],
    clusters=>[
      {lat=>35.68,lon=>139.7,rxkm=>90,rykm=>90,weight=>320},
      {lat=>34.7,lon=>135.5,rxkm=>80,rykm=>80,weight=>175},
      {lat=>35.18,lon=>136.9,rxkm=>70,rykm=>70,weight=>100},
      {lat=>33.6,lon=>130.4,rxkm=>80,rykm=>80,weight=>90},
      {lat=>43.06,lon=>141.35,rxkm=>80,rykm=>80,weight=>50},
      {lat=>38.27,lon=>140.87,rxkm=>80,rykm=>80,weight=>60},
      {lat=>26.21,lon=>127.68,rxkm=>40,rykm=>40,weight=>15},
    ],
    bgweight=>190,
  },
  {
    file=>'southafrica_fine.json', id=>'southafrica', name=>'South Africa',
    cities=>[
      {name=>'Johannesburg', lat=>-26.2041, lon=>28.0473},
      {name=>'Cape Town', lat=>-33.9249, lon=>18.4241},
      {name=>'Durban', lat=>-29.8587, lon=>31.0218},
      {name=>'Pretoria', lat=>-25.7479, lon=>28.2293},
      {name=>'Gqeberha', lat=>-33.9608, lon=>25.6022},
      {name=>'Bloemfontein', lat=>-29.0852, lon=>26.1596},
    ],
    clusters=>[
      {lat=>-26.0,lon=>28.1,rxkm=>90,rykm=>90,weight=>300},
      {lat=>-33.92,lon=>18.42,rxkm=>90,rykm=>90,weight=>180},
      {lat=>-29.86,lon=>31.02,rxkm=>90,rykm=>90,weight=>150},
      {lat=>-33.96,lon=>25.60,rxkm=>80,rykm=>80,weight=>80},
      {lat=>-29.09,lon=>26.16,rxkm=>90,rykm=>90,weight=>50},
    ],
    bgweight=>240,
  },
  {
    file=>'france_fine.json', id=>'france', name=>'France',
    cities=>[
      {name=>'Paris', lat=>48.8566, lon=>2.3522},
      {name=>'Marseille', lat=>43.2965, lon=>5.3698},
      {name=>'Lyon', lat=>45.7640, lon=>4.8357},
      {name=>'Toulouse', lat=>43.6047, lon=>1.4442},
      {name=>'Nantes', lat=>47.2184, lon=>-1.5536},
      {name=>'Strasbourg', lat=>48.5734, lon=>7.7521},
      {name=>'Bordeaux', lat=>44.8378, lon=>-0.5792},
    ],
    clusters=>[
      {lat=>48.86,lon=>2.35,rxkm=>90,rykm=>90,weight=>280},
      {lat=>45.76,lon=>4.84,rxkm=>70,rykm=>70,weight=>110},
      {lat=>43.30,lon=>5.37,rxkm=>80,rykm=>70,weight=>120},
      {lat=>43.60,lon=>1.44,rxkm=>70,rykm=>70,weight=>70},
      {lat=>47.22,lon=>-1.55,rxkm=>70,rykm=>70,weight=>70},
      {lat=>48.58,lon=>7.75,rxkm=>60,rykm=>60,weight=>60},
      {lat=>44.84,lon=>-0.58,rxkm=>60,rykm=>60,weight=>60},
    ],
    bgweight=>230,
  },
  {
    file=>'germany_fine.json', id=>'germany', name=>'Germany',
    cities=>[
      {name=>'Berlin', lat=>52.5200, lon=>13.4050},
      {name=>'Hamburg', lat=>53.5511, lon=>9.9937},
      {name=>'Munich', lat=>48.1351, lon=>11.5820},
      {name=>'Cologne', lat=>50.9375, lon=>6.9603},
      {name=>'Frankfurt', lat=>50.1109, lon=>8.6821},
      {name=>'Stuttgart', lat=>48.7758, lon=>9.1829},
      {name=>'Dresden', lat=>51.0504, lon=>13.7373},
    ],
    clusters=>[
      {lat=>52.52,lon=>13.40,rxkm=>80,rykm=>80,weight=>160},
      {lat=>51.45,lon=>7.2,rxkm=>90,rykm=>70,weight=>220},
      {lat=>50.11,lon=>8.68,rxkm=>70,rykm=>70,weight=>130},
      {lat=>48.14,lon=>11.58,rxkm=>80,rykm=>80,weight=>140},
      {lat=>48.78,lon=>9.18,rxkm=>60,rykm=>60,weight=>90},
      {lat=>53.55,lon=>10.0,rxkm=>70,rykm=>70,weight=>110},
      {lat=>51.05,lon=>13.74,rxkm=>60,rykm=>60,weight=>50},
    ],
    bgweight=>100,
  },
  {
    file=>'spain_fine.json', id=>'spain', name=>'Spain',
    cities=>[
      {name=>'Madrid', lat=>40.4168, lon=>-3.7038},
      {name=>'Barcelona', lat=>41.3874, lon=>2.1686},
      {name=>'Valencia', lat=>39.4699, lon=>-0.3763},
      {name=>'Seville', lat=>37.3891, lon=>-5.9845},
      {name=>'Bilbao', lat=>43.2630, lon=>-2.9350},
      {name=>'Málaga', lat=>36.7213, lon=>-4.4214},
    ],
    clusters=>[
      {lat=>40.42,lon=>-3.70,rxkm=>90,rykm=>90,weight=>260},
      {lat=>41.39,lon=>2.17,rxkm=>80,rykm=>80,weight=>220},
      {lat=>39.47,lon=>-0.38,rxkm=>70,rykm=>70,weight=>110},
      {lat=>37.39,lon=>-6.0,rxkm=>90,rykm=>80,weight=>130},
      {lat=>43.26,lon=>-2.93,rxkm=>60,rykm=>60,weight=>70},
      {lat=>36.72,lon=>-4.42,rxkm=>70,rykm=>60,weight=>90},
    ],
    bgweight=>120,
  },
  {
    file=>'italy_fine.json', id=>'italy', name=>'Italy',
    cities=>[
      {name=>'Rome', lat=>41.9028, lon=>12.4964},
      {name=>'Milan', lat=>45.4642, lon=>9.1900},
      {name=>'Naples', lat=>40.8518, lon=>14.2681},
      {name=>'Turin', lat=>45.0703, lon=>7.6869},
      {name=>'Bologna', lat=>44.4949, lon=>11.3426},
      {name=>'Florence', lat=>43.7696, lon=>11.2558},
      {name=>'Bari', lat=>41.1171, lon=>16.8719},
    ],
    clusters=>[
      {lat=>41.90,lon=>12.50,rxkm=>80,rykm=>80,weight=>190},
      {lat=>45.46,lon=>9.19,rxkm=>80,rykm=>70,weight=>230},
      {lat=>40.85,lon=>14.27,rxkm=>70,rykm=>60,weight=>150},
      {lat=>45.07,lon=>7.69,rxkm=>70,rykm=>60,weight=>90},
      {lat=>44.49,lon=>11.34,rxkm=>70,rykm=>60,weight=>90},
      {lat=>43.77,lon=>11.25,rxkm=>60,rykm=>60,weight=>70},
      {lat=>41.12,lon=>16.87,rxkm=>70,rykm=>60,weight=>70},
    ],
    bgweight=>110,
  },
  {
    file=>'poland_fine.json', id=>'poland', name=>'Poland',
    cities=>[
      {name=>'Warsaw', lat=>52.2297, lon=>21.0122},
      {name=>'Kraków', lat=>50.0647, lon=>19.9450},
      {name=>'Łódź', lat=>51.7592, lon=>19.4560},
      {name=>'Wrocław', lat=>51.1079, lon=>17.0385},
      {name=>'Poznań', lat=>52.4064, lon=>16.9252},
      {name=>'Gdańsk', lat=>54.3520, lon=>18.6466},
    ],
    clusters=>[
      {lat=>52.23,lon=>21.01,rxkm=>90,rykm=>90,weight=>220},
      {lat=>50.06,lon=>19.94,rxkm=>70,rykm=>70,weight=>130},
      {lat=>51.76,lon=>19.46,rxkm=>60,rykm=>60,weight=>90},
      {lat=>51.11,lon=>17.04,rxkm=>70,rykm=>60,weight=>100},
      {lat=>52.41,lon=>16.93,rxkm=>70,rykm=>60,weight=>90},
      {lat=>54.35,lon=>18.65,rxkm=>60,rykm=>60,weight=>90},
    ],
    bgweight=>280,
  },
  {
    file=>'ukraine_fine.json', id=>'ukraine', name=>'Ukraine',
    cities=>[
      {name=>'Kyiv', lat=>50.4501, lon=>30.5234},
      {name=>'Kharkiv', lat=>49.9935, lon=>36.2304},
      {name=>'Odesa', lat=>46.4825, lon=>30.7233},
      {name=>'Dnipro', lat=>48.4647, lon=>35.0462},
      {name=>'Lviv', lat=>49.8397, lon=>24.0297},
      {name=>'Zaporizhzhia', lat=>47.8388, lon=>35.1396},
    ],
    clusters=>[
      {lat=>50.45,lon=>30.52,rxkm=>90,rykm=>90,weight=>220},
      {lat=>49.99,lon=>36.23,rxkm=>70,rykm=>70,weight=>110},
      {lat=>46.48,lon=>30.73,rxkm=>70,rykm=>70,weight=>100},
      {lat=>48.46,lon=>35.05,rxkm=>70,rykm=>60,weight=>100},
      {lat=>49.84,lon=>24.03,rxkm=>70,rykm=>60,weight=>100},
      {lat=>47.84,lon=>35.14,rxkm=>60,rykm=>60,weight=>70},
    ],
    bgweight=>300,
  },
  {
    file=>'sweden_fine.json', id=>'sweden', name=>'Sweden',
    cities=>[
      {name=>'Stockholm', lat=>59.3293, lon=>18.0686},
      {name=>'Gothenburg', lat=>57.7089, lon=>11.9746},
      {name=>'Malmö', lat=>55.6050, lon=>13.0038},
      {name=>'Uppsala', lat=>59.8586, lon=>17.6389},
      {name=>'Örebro', lat=>59.2741, lon=>15.2066},
      {name=>'Umeå', lat=>63.8258, lon=>20.2630},
    ],
    clusters=>[
      {lat=>59.33,lon=>18.07,rxkm=>90,rykm=>90,weight=>300},
      {lat=>57.71,lon=>11.97,rxkm=>80,rykm=>70,weight=>200},
      {lat=>55.60,lon=>13.0,rxkm=>70,rykm=>60,weight=>150},
      {lat=>59.86,lon=>17.64,rxkm=>50,rykm=>50,weight=>60},
      {lat=>59.27,lon=>15.21,rxkm=>60,rykm=>60,weight=>50},
      {lat=>63.83,lon=>20.26,rxkm=>60,rykm=>80,weight=>40},
    ],
    bgweight=>200,
  },
  {
    file=>'netherlands_fine.json', id=>'netherlands', name=>'Netherlands',
    cities=>[
      {name=>'Amsterdam', lat=>52.3676, lon=>4.9041},
      {name=>'Rotterdam', lat=>51.9244, lon=>4.4777},
      {name=>'The Hague', lat=>52.0705, lon=>4.3007},
      {name=>'Utrecht', lat=>52.0907, lon=>5.1214},
      {name=>'Eindhoven', lat=>51.4416, lon=>5.4697},
      {name=>'Groningen', lat=>53.2194, lon=>6.5665},
    ],
    clusters=>[
      {lat=>52.37,lon=>4.90,rxkm=>50,rykm=>50,weight=>220},
      {lat=>51.92,lon=>4.48,rxkm=>50,rykm=>50,weight=>220},
      {lat=>52.09,lon=>5.12,rxkm=>40,rykm=>40,weight=>130},
      {lat=>51.44,lon=>5.48,rxkm=>60,rykm=>50,weight=>120},
      {lat=>53.22,lon=>6.57,rxkm=>60,rykm=>60,weight=>60},
    ],
    bgweight=>250,
  },
  {
    file=>'greece_fine.json', id=>'greece', name=>'Greece',
    cities=>[
      {name=>'Athens', lat=>37.9838, lon=>23.7275},
      {name=>'Thessaloniki', lat=>40.6401, lon=>22.9444},
      {name=>'Patras', lat=>38.2466, lon=>21.7346},
      {name=>'Larissa', lat=>39.6390, lon=>22.4191},
      {name=>'Volos', lat=>39.3622, lon=>22.9422},
    ],
    clusters=>[
      {lat=>37.98,lon=>23.73,rxkm=>80,rykm=>80,weight=>380},
      {lat=>40.64,lon=>22.94,rxkm=>70,rykm=>60,weight=>180},
      {lat=>38.25,lon=>21.73,rxkm=>60,rykm=>50,weight=>90},
      {lat=>39.64,lon=>22.42,rxkm=>60,rykm=>50,weight=>70},
      {lat=>39.36,lon=>22.94,rxkm=>50,rykm=>50,weight=>50},
    ],
    bgweight=>230,
  },
  {
    file=>'portugal_fine.json', id=>'portugal', name=>'Portugal',
    cities=>[
      {name=>'Lisbon', lat=>38.7223, lon=>-9.1393},
      {name=>'Porto', lat=>41.1579, lon=>-8.6291},
      {name=>'Braga', lat=>41.5454, lon=>-8.4265},
      {name=>'Coimbra', lat=>40.2033, lon=>-8.4103},
      {name=>'Faro', lat=>37.0194, lon=>-7.9304},
    ],
    clusters=>[
      {lat=>38.72,lon=>-9.14,rxkm=>80,rykm=>80,weight=>380},
      {lat=>41.15,lon=>-8.61,rxkm=>70,rykm=>60,weight=>250},
      {lat=>41.55,lon=>-8.42,rxkm=>50,rykm=>50,weight=>90},
      {lat=>40.21,lon=>-8.43,rxkm=>60,rykm=>50,weight=>80},
      {lat=>37.02,lon=>-7.93,rxkm=>60,rykm=>50,weight=>70},
    ],
    bgweight=>130,
  },
  {
    file=>'pakistan_fine.json', id=>'pakistan', name=>'Pakistan',
    cities=>[
      {name=>'Karachi', lat=>24.8607, lon=>67.0011},
      {name=>'Lahore', lat=>31.5497, lon=>74.3436},
      {name=>'Faisalabad', lat=>31.4180, lon=>73.0790},
      {name=>'Islamabad', lat=>33.6844, lon=>73.0479},
      {name=>'Multan', lat=>30.1575, lon=>71.5249},
      {name=>'Peshawar', lat=>34.0151, lon=>71.5805},
    ],
    clusters=>[
      {lat=>24.86,lon=>67.01,rxkm=>70,rykm=>70,weight=>220},
      {lat=>31.55,lon=>74.34,rxkm=>90,rykm=>80,weight=>230},
      {lat=>31.42,lon=>73.09,rxkm=>60,rykm=>60,weight=>90},
      {lat=>33.68,lon=>73.05,rxkm=>60,rykm=>60,weight=>90},
      {lat=>30.20,lon=>71.47,rxkm=>60,rykm=>60,weight=>80},
      {lat=>34.01,lon=>71.58,rxkm=>60,rykm=>60,weight=>70},
    ],
    bgweight=>220,
  },
  {
    file=>'bangladesh_fine.json', id=>'bangladesh', name=>'Bangladesh',
    cities=>[
      {name=>'Dhaka', lat=>23.8103, lon=>90.4125},
      {name=>'Chittagong', lat=>22.3569, lon=>91.7832},
      {name=>'Khulna', lat=>22.8456, lon=>89.5403},
      {name=>'Rajshahi', lat=>24.3745, lon=>88.6042},
      {name=>'Sylhet', lat=>24.8949, lon=>91.8687},
    ],
    clusters=>[
      {lat=>23.81,lon=>90.41,rxkm=>80,rykm=>80,weight=>350},
      {lat=>22.34,lon=>91.83,rxkm=>70,rykm=>70,weight=>180},
      {lat=>22.85,lon=>89.55,rxkm=>60,rykm=>60,weight=>110},
      {lat=>24.37,lon=>88.60,rxkm=>60,rykm=>60,weight=>90},
      {lat=>24.90,lon=>91.87,rxkm=>60,rykm=>60,weight=>70},
    ],
    bgweight=>200,
  },
  {
    file=>'vietnam_fine.json', id=>'vietnam', name=>'Vietnam',
    cities=>[
      {name=>'Hanoi', lat=>21.0285, lon=>105.8542},
      {name=>'Ho Chi Minh City', lat=>10.8231, lon=>106.6297},
      {name=>'Da Nang', lat=>16.0544, lon=>108.2022},
      {name=>'Can Tho', lat=>10.0452, lon=>105.7469},
      {name=>'Hai Phong', lat=>20.8449, lon=>106.6881},
    ],
    clusters=>[
      {lat=>21.03,lon=>105.85,rxkm=>80,rykm=>70,weight=>240},
      {lat=>10.82,lon=>106.63,rxkm=>80,rykm=>70,weight=>260},
      {lat=>10.03,lon=>105.78,rxkm=>70,rykm=>60,weight=>130},
      {lat=>16.05,lon=>108.22,rxkm=>60,rykm=>60,weight=>80},
      {lat=>20.86,lon=>106.68,rxkm=>50,rykm=>50,weight=>70},
    ],
    bgweight=>220,
  },
  {
    file=>'thailand_fine.json', id=>'thailand', name=>'Thailand',
    cities=>[
      {name=>'Bangkok', lat=>13.7563, lon=>100.5018},
      {name=>'Chiang Mai', lat=>18.7883, lon=>98.9853},
      {name=>'Nakhon Ratchasima', lat=>14.9799, lon=>102.0977},
      {name=>'Hat Yai', lat=>7.0086, lon=>100.4747},
      {name=>'Pattaya', lat=>12.9236, lon=>100.8825},
    ],
    clusters=>[
      {lat=>13.75,lon=>100.50,rxkm=>90,rykm=>90,weight=>380},
      {lat=>18.79,lon=>98.99,rxkm=>70,rykm=>70,weight=>110},
      {lat=>14.97,lon=>102.10,rxkm=>90,rykm=>80,weight=>150},
      {lat=>7.01,lon=>100.48,rxkm=>60,rykm=>60,weight=>80},
      {lat=>12.93,lon=>100.88,rxkm=>50,rykm=>50,weight=>60},
    ],
    bgweight=>220,
  },
  {
    file=>'southkorea_fine.json', id=>'southkorea', name=>'South Korea',
    cities=>[
      {name=>'Seoul', lat=>37.5665, lon=>126.9780},
      {name=>'Busan', lat=>35.1796, lon=>129.0756},
      {name=>'Incheon', lat=>37.4563, lon=>126.7052},
      {name=>'Daegu', lat=>35.8714, lon=>128.6014},
      {name=>'Daejeon', lat=>36.3504, lon=>127.3845},
      {name=>'Gwangju', lat=>35.1595, lon=>126.8526},
    ],
    clusters=>[
      {lat=>37.57,lon=>126.98,rxkm=>70,rykm=>70,weight=>450},
      {lat=>35.18,lon=>129.08,rxkm=>60,rykm=>60,weight=>180},
      {lat=>35.87,lon=>128.60,rxkm=>50,rykm=>50,weight=>100},
      {lat=>36.35,lon=>127.38,rxkm=>50,rykm=>50,weight=>80},
      {lat=>35.16,lon=>126.85,rxkm=>50,rykm=>50,weight=>70},
    ],
    bgweight=>120,
  },
  {
    file=>'saudiarabia_fine.json', id=>'saudiarabia', name=>'Saudi Arabia',
    cities=>[
      {name=>'Riyadh', lat=>24.7136, lon=>46.6753},
      {name=>'Jeddah', lat=>21.4858, lon=>39.1925},
      {name=>'Mecca', lat=>21.3891, lon=>39.8579},
      {name=>'Medina', lat=>24.5247, lon=>39.5692},
      {name=>'Dammam', lat=>26.4207, lon=>50.0888},
    ],
    clusters=>[
      {lat=>24.71,lon=>46.68,rxkm=>90,rykm=>90,weight=>300},
      {lat=>21.49,lon=>39.19,rxkm=>70,rykm=>70,weight=>180},
      {lat=>21.39,lon=>39.86,rxkm=>50,rykm=>50,weight=>100},
      {lat=>24.47,lon=>39.61,rxkm=>50,rykm=>50,weight=>70},
      {lat=>26.43,lon=>50.10,rxkm=>60,rykm=>60,weight=>130},
    ],
    bgweight=>220,
  },
  {
    file=>'kenya_fine.json', id=>'kenya', name=>'Kenya',
    cities=>[
      {name=>'Nairobi', lat=>-1.2921, lon=>36.8219},
      {name=>'Mombasa', lat=>-4.0435, lon=>39.6682},
      {name=>'Kisumu', lat=>-0.0917, lon=>34.7680},
      {name=>'Nakuru', lat=>-0.3031, lon=>36.0800},
      {name=>'Eldoret', lat=>0.5143, lon=>35.2698},
    ],
    clusters=>[
      {lat=>-1.29,lon=>36.82,rxkm=>70,rykm=>70,weight=>280},
      {lat=>-4.04,lon=>39.66,rxkm=>60,rykm=>60,weight=>130},
      {lat=>-0.09,lon=>34.77,rxkm=>60,rykm=>60,weight=>110},
      {lat=>-0.30,lon=>36.07,rxkm=>60,rykm=>60,weight=>90},
      {lat=>0.51,lon=>35.27,rxkm=>60,rykm=>60,weight=>70},
    ],
    bgweight=>320,
  },
  {
    file=>'ethiopia_fine.json', id=>'ethiopia', name=>'Ethiopia',
    cities=>[
      {name=>'Addis Ababa', lat=>9.0320, lon=>38.7469},
      {name=>'Dire Dawa', lat=>9.5931, lon=>41.8661},
      {name=>"Mek'ele", lat=>13.4967, lon=>39.4753},
      {name=>'Gondar', lat=>12.6000, lon=>37.4667},
      {name=>'Hawassa', lat=>7.0504, lon=>38.4955},
    ],
    clusters=>[
      {lat=>9.03,lon=>38.74,rxkm=>80,rykm=>80,weight=>280},
      {lat=>9.59,lon=>41.87,rxkm=>60,rykm=>60,weight=>90},
      {lat=>13.50,lon=>39.47,rxkm=>60,rykm=>60,weight=>100},
      {lat=>12.60,lon=>37.47,rxkm=>60,rykm=>60,weight=>90},
      {lat=>7.05,lon=>38.48,rxkm=>60,rykm=>60,weight=>100},
    ],
    bgweight=>340,
  },
  {
    file=>'morocco_fine.json', id=>'morocco', name=>'Morocco',
    cities=>[
      {name=>'Casablanca', lat=>33.5731, lon=>-7.5898},
      {name=>'Rabat', lat=>34.0209, lon=>-6.8416},
      {name=>'Marrakesh', lat=>31.6295, lon=>-7.9811},
      {name=>'Fez', lat=>34.0331, lon=>-5.0003},
      {name=>'Tangier', lat=>35.7595, lon=>-5.8340},
    ],
    clusters=>[
      {lat=>33.57,lon=>-7.59,rxkm=>70,rykm=>70,weight=>280},
      {lat=>34.02,lon=>-6.83,rxkm=>50,rykm=>50,weight=>120},
      {lat=>31.63,lon=>-7.99,rxkm=>60,rykm=>60,weight=>110},
      {lat=>34.03,lon=>-5.00,rxkm=>60,rykm=>60,weight=>100},
      {lat=>35.76,lon=>-5.83,rxkm=>50,rykm=>50,weight=>90},
    ],
    bgweight=>300,
  },
  {
    file=>'ghana_fine.json', id=>'ghana', name=>'Ghana',
    cities=>[
      {name=>'Accra', lat=>5.6037, lon=>-0.1870},
      {name=>'Kumasi', lat=>6.6885, lon=>-1.6244},
      {name=>'Sekondi-Takoradi', lat=>4.9344, lon=>-1.7554},
      {name=>'Tamale', lat=>9.4008, lon=>-0.8393},
      {name=>'Cape Coast', lat=>5.1053, lon=>-1.2466},
    ],
    clusters=>[
      {lat=>5.60,lon=>-0.19,rxkm=>60,rykm=>60,weight=>300},
      {lat=>6.69,lon=>-1.62,rxkm=>60,rykm=>60,weight=>180},
      {lat=>4.93,lon=>-1.76,rxkm=>50,rykm=>50,weight=>100},
      {lat=>9.40,lon=>-0.85,rxkm=>70,rykm=>70,weight=>90},
      {lat=>5.11,lon=>-1.25,rxkm=>40,rykm=>40,weight=>60},
    ],
    bgweight=>270,
  },
  {
    file=>'drcongo_fine.json', id=>'drcongo', name=>'DR Congo',
    cities=>[
      {name=>'Kinshasa', lat=>-4.4419, lon=>15.2663},
      {name=>'Lubumbashi', lat=>-11.6609, lon=>27.4794},
      {name=>'Mbuji-Mayi', lat=>-6.1500, lon=>23.6000},
      {name=>'Kisangani', lat=>0.5167, lon=>25.2000},
      {name=>'Goma', lat=>-1.6792, lon=>29.2228},
    ],
    clusters=>[
      {lat=>-4.44,lon=>15.27,rxkm=>80,rykm=>80,weight=>300},
      {lat=>-11.66,lon=>27.48,rxkm=>60,rykm=>60,weight=>110},
      {lat=>-6.15,lon=>23.60,rxkm=>60,rykm=>60,weight=>100},
      {lat=>0.52,lon=>25.20,rxkm=>60,rykm=>60,weight=>70},
      {lat=>-1.68,lon=>29.22,rxkm=>50,rykm=>50,weight=>70},
    ],
    bgweight=>350,
  },
  {
    file=>'algeria_fine.json', id=>'algeria', name=>'Algeria',
    cities=>[
      {name=>'Algiers', lat=>36.7538, lon=>3.0588},
      {name=>'Oran', lat=>35.6969, lon=>-0.6331},
      {name=>'Constantine', lat=>36.3650, lon=>6.6147},
      {name=>'Annaba', lat=>36.9000, lon=>7.7667},
      {name=>'Blida', lat=>36.4700, lon=>2.8300},
    ],
    clusters=>[
      {lat=>36.75,lon=>3.06,rxkm=>70,rykm=>70,weight=>280},
      {lat=>35.70,lon=>-0.63,rxkm=>60,rykm=>60,weight=>150},
      {lat=>36.37,lon=>6.61,rxkm=>60,rykm=>60,weight=>120},
      {lat=>36.90,lon=>7.77,rxkm=>50,rykm=>50,weight=>80},
      {lat=>36.47,lon=>2.83,rxkm=>40,rykm=>40,weight=>70},
    ],
    bgweight=>300,
  },
  {
    file=>'argentina_fine.json', id=>'argentina', name=>'Argentina',
    cities=>[
      {name=>'Buenos Aires', lat=>-34.6037, lon=>-58.3816},
      {name=>'Córdoba', lat=>-31.4201, lon=>-64.1888},
      {name=>'Rosario', lat=>-32.9468, lon=>-60.6393},
      {name=>'Mendoza', lat=>-32.8895, lon=>-68.8458},
      {name=>'Tucumán', lat=>-26.8241, lon=>-65.2226},
    ],
    clusters=>[
      {lat=>-34.60,lon=>-58.38,rxkm=>100,rykm=>100,weight=>400},
      {lat=>-31.42,lon=>-64.18,rxkm=>70,rykm=>70,weight=>130},
      {lat=>-32.95,lon=>-60.64,rxkm=>60,rykm=>60,weight=>100},
      {lat=>-32.89,lon=>-68.85,rxkm=>60,rykm=>60,weight=>80},
      {lat=>-26.82,lon=>-65.22,rxkm=>60,rykm=>60,weight=>70},
    ],
    bgweight=>220,
  },
  {
    file=>'colombia_fine.json', id=>'colombia', name=>'Colombia',
    cities=>[
      {name=>'Bogotá', lat=>4.7110, lon=>-74.0721},
      {name=>'Medellín', lat=>6.2442, lon=>-75.5812},
      {name=>'Cali', lat=>3.4516, lon=>-76.5320},
      {name=>'Barranquilla', lat=>10.9639, lon=>-74.7964},
      {name=>'Cartagena', lat=>10.3910, lon=>-75.4794},
    ],
    clusters=>[
      {lat=>4.71,lon=>-74.07,rxkm=>70,rykm=>70,weight=>280},
      {lat=>6.25,lon=>-75.56,rxkm=>60,rykm=>60,weight=>160},
      {lat=>3.45,lon=>-76.53,rxkm=>60,rykm=>60,weight=>130},
      {lat=>10.96,lon=>-74.80,rxkm=>60,rykm=>60,weight=>110},
      {lat=>10.39,lon=>-75.51,rxkm=>50,rykm=>50,weight=>70},
    ],
    bgweight=>250,
  },
  {
    file=>'peru_fine.json', id=>'peru', name=>'Peru',
    cities=>[
      {name=>'Lima', lat=>-12.0464, lon=>-77.0428},
      {name=>'Arequipa', lat=>-16.4090, lon=>-71.5375},
      {name=>'Trujillo', lat=>-8.1116, lon=>-79.0288},
      {name=>'Chiclayo', lat=>-6.7714, lon=>-79.8409},
      {name=>'Cusco', lat=>-13.5320, lon=>-71.9675},
    ],
    clusters=>[
      {lat=>-12.05,lon=>-77.04,rxkm=>80,rykm=>80,weight=>380},
      {lat=>-16.41,lon=>-71.54,rxkm=>60,rykm=>60,weight=>110},
      {lat=>-8.11,lon=>-79.03,rxkm=>60,rykm=>60,weight=>100},
      {lat=>-6.77,lon=>-79.84,rxkm=>50,rykm=>50,weight=>80},
      {lat=>-13.53,lon=>-71.97,rxkm=>60,rykm=>60,weight=>80},
    ],
    bgweight=>250,
  },
  {
    file=>'chile_fine.json', id=>'chile', name=>'Chile',
    cities=>[
      {name=>'Santiago', lat=>-33.4489, lon=>-70.6693},
      {name=>'Valparaíso', lat=>-33.0472, lon=>-71.6127},
      {name=>'Concepción', lat=>-36.8270, lon=>-73.0503},
      {name=>'La Serena', lat=>-29.9027, lon=>-71.2519},
      {name=>'Antofagasta', lat=>-23.6509, lon=>-70.3975},
    ],
    clusters=>[
      {lat=>-33.45,lon=>-70.67,rxkm=>80,rykm=>80,weight=>420},
      {lat=>-33.05,lon=>-71.61,rxkm=>50,rykm=>50,weight=>110},
      {lat=>-36.83,lon=>-73.05,rxkm=>60,rykm=>60,weight=>110},
      {lat=>-29.90,lon=>-71.25,rxkm=>50,rykm=>50,weight=>70},
      {lat=>-23.65,lon=>-70.40,rxkm=>60,rykm=>60,weight=>60},
    ],
    bgweight=>230,
  },
);

print "// Country boundary and city data derived from OpenStreetMap contributors (ODbL 1.0),\n";
print "// fetched via the Nominatim API and simplified for use as game map overlays.\n";
print "// https://www.openstreetmap.org/copyright\n";
print "const COUNTRY_DEFS = [\n";
my $firstC = 1;
for my $c (@countries) {
    print ",\n" unless $firstC;
    $firstC = 0;
    emit_country(%$c);
}
print "\n];\n";
