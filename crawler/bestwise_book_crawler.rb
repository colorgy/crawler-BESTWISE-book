require 'iconv'
require 'crawler_rocks'
require 'json'
require 'isbn'
require 'pry'
require 'book_toolkit'

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

  def initialize  update_progress: nil, after_each: nil
    @update_progress_proc = update_progress
    @after_each_proc = after_each

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

          begin
            @books[book_number][:isbn] = BookToolkit.to_isbn13(@books[book_number][:isbn])
          rescue Exception => e
          end
          @books[book_number][:isbn] = nil if @books[book_number][:isbn] && @books[book_number][:isbn].empty?

          @books[book_number][:external_image_url] = image_urls[i]
          @books[book_number][:url] = url
          @books[book_number][:known_supplier] = 'bestwise'

          sleep(1) until (
            @threads.delete_if { |t| !t.status };  # remove dead (ended) threads
            @threads.count < (ENV['MAX_THREADS'] || 30)
          )
          @threads << Thread.new do
            r = RestClient.get url
            doc = Nokogiri::HTML(r)

            list_items = doc.css('.Book .title li')
            list_items.map(&:text).each do |li|
              key = ATTR_KEY[li.rpartition('：')[0]]
              key && @books[book_number][key] ||= li.rpartition('：')[-1].strip
            end

            @books[book_number][:price] = (@books[book_number][:price].to_i == 0) ? \
                                            nil : @books[book_number][:price].to_i
            @books[book_number][:edition] = @books[book_number][:edition].gsub(/[^\d]/, '').to_i
            @books[book_number][:isbn] = nil if @books[book_number][:isbn] && @books[book_number][:isbn].empty?

            @after_each_proc.call(book: @books[book_number]) if @after_each_proc
          end
        end

        # do pagination
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

end

# cc = BestwiseBookCrawler.new
# File.write('bestwise_books.json', JSON.pretty_generate(cc.books))
