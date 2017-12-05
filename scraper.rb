require 'scraperwiki'
require 'mechanize'
require 'addressable/uri'
require 'date'
require 'json'
require 'digest/sha1'
require 'active_support/core_ext/hash/slice'

LIST_URL = 'https://www.bmi.bund.de/SiteGlobals/Forms/suche/gesetzgebungsverfahren-formular.html'

m = Mechanize.new
mp = m.get(LIST_URL)

BASE = mp.bases.first.href

results = []

loop do
	result_items = mp.css('.c-search-teaser.Law')
	result_items.each do |row|
		link = row.css('.c-search-teaser__h a').first
		title = link.text.strip
		path = link.attributes['href']
		url = Addressable::URI.join(BASE, path).normalize.to_s

		x = {
			title: title,
			overview: url
		}
		results << x
	end

	link = mp.at_css('.navIndex .forward a')
	break if link.nil?

	path = link.attributes['href']
	url = Addressable::URI.join(BASE, path).normalize.to_s

	mp = m.get url
end

# Phase 2: scrape detail pages
headline2key = {
	'Referentenentwurf' => :draft,
	'Verbandsstellungnahme' => :statement,
	'Verbändestellungnahmen' => :statement,
	'Stellungnahmen' => :statement
}

def link_object(link)
	title = link.text.strip
	path = link.attributes['href'].to_s.strip
	linkobj(title, Addressable::URI.join(BASE, path).normalize.to_s)
end

def linkobj(title, uri)
	uri = Addressable::URI.parse(uri).normalize
	url = uri.to_s

	filename = "#{Digest::SHA256.hexdigest(url)[0...8]}_#{uri.basename.to_s}"

	{
		title: title,
		url: url,
		filename: filename
	}
end

results.each do |row|
	mp = m.get row[:overview]

	headline = mp.at_css('.c-content-stage__headline')
	row[:title] = headline.text.strip
	row[:law] = []

	linked = mp.css('.c-more__link')
	linked.each do |link|
		path = link.attributes['href'].to_s.strip
		if path.include?('bgbl.de')
			begin
				title = link.text.strip
				uri = Addressable::URI.join(path).normalize
				query = uri.normalized_query
				if query.include?('&jumpTo=')
					jumpTo = query.match(/jumpTo=(.+?)(?:&|$)/)[1]
					start = "%2F%2F%2A%5B%40attr_id%3D%27#{jumpTo}%27%5D"
				else
					start = query.match(/start=(.+?)(?:&|$)/)[1]
				end
				bgbluri = Addressable::URI.parse("https://www.bgbl.de/xaver/bgbl/text.xav?skin=pdf&start=#{start}").normalize.to_s
				m.get(uri) # unlock session
				bgblpage = m.get(bgbluri)
				fakeimg = bgblpage.at_css('.xaver-PDF img')
				pdfurl = fakeimg.attributes['src']
				pdf = m.get(pdfurl)

				a = linkobj(title, pdf.uri.to_s)
				a[:source] = bgbluri
				row[:law] << a
			rescue
				row[:law] << link_object(link)
			end
		else
			row[:law] << link_object(link)
		end
	end

	container = mp.at_css('.c-content-linklist__wrapper.row')
	container.css('h3').each do |headline|
		title = headline.text.strip
		key = headline2key[title]
		next if key.nil?

		row[key] = []

		links = headline.next_element.css('a')
		links.each do |link|
			row[key] << link_object(link)
		end
	end
end

# link buzer
results.each do |row|
	row[:law].each do |law|
		buzer_uri = nil
		if law[:url].include?('bgbl.de')
			um = law[:url].match(/\/bgbl[12](\d+)s(\d+)_(?:\d+).pdf$/)
			next if um.nil?
			buzer_uri = "https://www.buzer.de/s1.htm?a=&g=20#{um[1]}+#{um[2]}"
		else
			buzer_uri = Addressable::URI.parse("https://www.buzer.de/s1.htm?a=&g=#{row[:title]}").normalize.to_s
			next
		end
		next if buzer_uri.nil?
		law[:buzer] = buzer_uri

		page = m.get(buzer_uri)
		link = page.at_css('div.g a[href$="l.htm"]')
		next if link.nil?
		law[:buzer_diff] = link.attributes['href'].to_s.strip
	end
end

results.each do |row|
	key = row[:title].downcase.gsub(/[\s.\/_]/, ' ').squeeze(' ').strip.gsub(/[^\w-]/, '').tr(' ', '-')
	ScraperWiki.save_sqlite([:key], row.slice(:title, :overview).merge({key: key}))
	ScraperWiki.save_sqlite([:key], row[:law].map { |o| o.merge({ key: key }) }, 'law') unless row[:law].nil?
	ScraperWiki.save_sqlite([:key], row[:draft].map { |o| o.merge({ key: key }) }, 'draft') unless row[:draft].nil?
	ScraperWiki.save_sqlite([:key], row[:statement].map { |o| o.merge({ key: key }) }, 'statement') unless row[:statement].nil?
end