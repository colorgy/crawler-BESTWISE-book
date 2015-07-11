require 'iconv'
require 'crawler_rocks'
require 'json'
require 'isbn'
require 'pry'

require 'thread'
require 'thwait'

class BestwiseBookCrawler
  include CrawlerRocks::DSL

  ATTR_KEY = {
    "作者" => :author,
    "書號" => :internal_code,
    "ISBN" => :isbn,
    "定價" => :price,
    "出版社" => :publisher,
    "版次" => :edition,
    "主編" => :author, # 應該要多幾個欄位的 =w=，暫時先這樣
    "審訂" => :author,
    "總校閱" => :author
  }

  def initialize
    @index_url = "http://www.bestwise.com.tw/Book_default.aspx"
  end

  def books
    @books = {}

    visit @index_url

    category_urls = @doc.css('a') \
                      .map{ |a| a[:href] }
                      .select{ |href| href.include?('book_default.aspx?no=') }
                      .uniq
                      .map{ |href| URI.join(@index_url, href).to_s }

    category_urls.each_with_index do |start_url, cat_index|
      @threads = []

      r = RestClient.get start_url
      doc = Nokogiri::HTML(r)

      loop do
        image_urls = doc.xpath('//tr[@class="booktb"]/td[@width="10%"]//img/@src')
                      .map{|src| URI.join(@index_url, src.to_s).to_s }

        attr_lists = doc.xpath('//tr[@class="booktb"]//div[@class="title15"]/ul')

        attr_lists.count.times do |i|
          list_items = attr_lists[i].xpath('li')

          url = URI.join(@index_url, list_items[0].xpath('a//@href').to_s).to_s
          book_number = url.match(/(?<=bno=).+/).to_s

          @books[book_number] ||= {}
          @books[book_number][:name] = list_items[0] && list_items[0].text
          list_items[1..-1].map(&:text).each{ |li|
            @books[book_number][ATTR_KEY[li.split('：')[0]]] = li.rpartition('：')[-1].strip
          }

          @books[book_number][:price] = (@books[book_number][:price].to_i == 0) ? \
                                          nil : @books[book_number][:price].to_i
          @books[book_number][:isbn] = isbn_to_13(@books[book_number][:isbn])
          @books[book_number][:isbn] = nil if @books[book_number][:isbn] && @books[book_number][:isbn].empty?

          @books[book_number][:external_image_url] = image_urls[i]
          @books[book_number][:url] = url

          sleep(1) until (
            @threads.delete_if { |t| !t.status };  # remove dead (ended) threads
            @threads.count < (ENV['MAX_THREADS'] || 30)
          )
          @threads << Thread.new do
            r = RestClient.get url
            doc = Nokogiri::HTML(r)

            list_items = doc.css('.Book .title li')
            list_items.map(&:text).each do |li|
              key = ATTR_KEY[li.split('：')[0]]
              key && @books[book_number][key] ||= li.rpartition('：')[-1].strip
            end

            @books[book_number][:price] = (@books[book_number][:price].to_i == 0) ? \
                                            nil : @books[book_number][:price].to_i
            @books[book_number][:edition] = @books[book_number][:edition].gsub(/[^\d]/, '').to_i
            @books[book_number][:isbn] = nil if @books[book_number][:isbn] && @books[book_number][:isbn].empty?
          end
        end

        # do paginztion
        next_href = doc.xpath("//a[.='>  ']//@href").to_s
        if next_href.empty?
          break
        else
          r = RestClient.get URI.join(@index_url, next_href).to_s
          doc = Nokogiri::HTML(r)
        end

      end # end loop do
      ThreadsWait.all_waits(*@threads)
      puts "#{cat_index + 1} / #{category_urls.count}"
    end # end each category

    @books.values
  end # end books

  def isbn_to_13 isbn
    case isbn.length
    when 13
      return ISBN.thirteen isbn
    when 10
      return ISBN.thirteen isbn
    when 12
      return "#{isbn}#{isbn_checksum(isbn)}"
    when 9
      return ISBN.thirteen("#{isbn}#{isbn_checksum(isbn)}")
    end
  end

  def isbn_checksum(isbn)
    isbn.gsub!(/[^(\d|X)]/, '')
    c = 0
    if isbn.length <= 10
      10.downto(2) {|i| c += isbn[10-i].to_i * i}
      c %= 11
      c = 11 - c
      c ='X' if c == 10
      return c
    elsif isbn.length <= 13
      (1..11).step(2) {|i| c += isbn[i].to_i}
      c *= 3
      (0..11).step(2) {|i| c += isbn[i].to_i}
      c = (220-c) % 10
      return c
    end
  end
end

cc = BestwiseBookCrawler.new
File.write('bestwise_books.json', JSON.pretty_generate(cc.books))
