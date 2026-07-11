import Foundation
import Testing
@testable import CoverDrop

struct AlbumNameCleaningTests {
    @Test("真实目录噪音会清洗为封面搜索需要的核心专辑名")
    func cleansDatabaseDerivedAlbumNames() {
        let cases: [(input: String, artist: String?, expected: String)] = [
            ("2002-坚持到底", "阿杜", "坚持到底"),
            ("[2013]天使與魔鬼的對話", "蔡健雅", "天使与魔鬼的对话"),
            ("[Qobuz] 蔡健雅 - Bored 1997 [24-96]", "蔡健雅", "Bored"),
            ("[Sony] - 蔡健雅 - 若你碰到他 - 16-44", "蔡健雅", "若你碰到他"),
            ("蔡琴 - [(1983) 昨夜之灯] (FLAC)", "蔡琴", "昨夜之灯"),
            ("蔡琴 - [(1999) 机遇 第一版] (黄色版) (FLAC)", "蔡琴", "机遇"),
            ("蔡琴-《机遇.淡水小镇原声带》2004 DSD DFF", "蔡琴", "机遇.淡水小镇原声带"),
            ("半吨兄弟《2023VIP数字专辑(1)》[FLAC+CUE]", "半吨兄弟", "2023VIP数字专辑(1)"),
            ("1、阿梨粤《难得有情人》1：1母盘直刻限量编号[正版原抓WAV+CUE]", "阿梨粤", "难得有情人"),
            ("白晓 - 寂寞秋思(HQCD) 2012 1644", "白晓", "寂寞秋思"),
            ("1994-03郭富城 - AK-47（港首版+华星）", "郭富城", "AK-47"),
            ("1997-04郭富城 - 分享自由-分享愛（珍藏版3寸CD）（港首版+华纳）", "郭富城", "分享自由-分享爱"),
            ("2001.07.09 - 孙燕姿 - 《风筝》", "孙燕姿", "风筝"),
            ("[Hires]孙燕姿《跳舞的梵谷》24-96", "孙燕姿", "跳舞的梵谷"),
            ("东升魔音唱片 孙露 第九张专辑《寂寞诱惑》WAV+CUE", "孙露", "寂寞诱惑"),
            ("陈明.-.[寂寞让我如此美丽].专辑.(APE)", "陈明", "寂寞让我如此美丽"),
            ("莫文蔚.-.[超级金曲精选].专辑.(FLAC)", "莫文蔚", "超级金曲精选"),
            ("蔡琴（你的眼神）专辑", "蔡琴", "你的眼神"),
            ("1994- Alan Tam 24K Gold 金藏集 4CD[天龙版][WAV]", "谭咏麟", "Alan Tam 24K Gold 金藏集"),
            ("最好的蔡琴 Tsai Chin BEST - 1bit 2.8224MHz", "蔡琴", "最好的蔡琴 Tsai Chin BEST"),
            ("1988-20 GREATEST HITS", "林子祥", "20 GREATEST HITS"),
            ("2013 [The Best of G.E.M. 2008~2012]", "邓紫棋", "The Best of G.E.M. 2008~2012"),
            ("2003-2002年的第一场雪[WAV]", "刀郎", "2002年的第一场雪"),
            ("林子祥精选集 [百代珍藏套装之7]", "林子祥", "林子祥精选集"),
            ("[Hires]林忆莲 - 0 2024 24-96", "林忆莲", "0"),
            ("[Qobuz]陈奕迅 - 是但求其爱 2020 [FLAC24bit48Khz]", "陈奕迅", "是但求其爱"),
            ("张国荣好精选(SACD)[新宝艺]", "张国荣", "张国荣好精选"),
            ("张国荣.-.[告别当年情珍藏版].专辑.(APE)", "张国荣", "告别当年情珍藏版"),
            ("赵传2014-歌声传情 3CD[广东音像][WAV+CUE]CD1", "赵传", "歌声传情"),
            ("1999郭富城 - 我知道你要什么(单曲港首+华纳)", "郭富城", "我知道你要什么"),
            ("【炫舞e时空收藏】韩宝仪《2010-抒情精粹》VOL.1[WAV+CUE]", "韩宝仪", "抒情精粹"),
            ("《韩宝仪[1993-男女对唱歌集》[WAV]", "韩宝仪", "男女对唱歌集")
        ]

        for testCase in cases {
            let actual = AlbumNameCleaning.cleanAlbumName(
                testCase.input,
                artistName: testCase.artist
            )
            #expect(actual == testCase.expected)
            #expect(AlbumNameCleaning.cleanAlbumName(actual, artistName: testCase.artist) == actual)
        }
    }

    @Test("正式名称里的年份编号格式字样和标点不会被误删")
    func preservesSemanticNumbersAndPunctuation() {
        let names = [
            "1989",
            "2001 A Space Odyssey",
            "1989 Taylor's Version",
            "20 GREATEST HITS",
            "No.1",
            "24K Magic",
            "J-GAME",
            "AK-47",
            "AC/DC",
            "Blink-182",
            "A-ha",
            "2023VIP数字专辑(1)",
            "银色月光下(演唱会)",
            "The Best of G.E.M. 2008-2012",
            "3 Years",
            "8.15pm",
            "Dahlia II",
            "家 III",
            "No.13 作品 - 跳舞的梵谷"
        ]

        for name in names {
            #expect(AlbumNameCleaning.cleanAlbumName(name, artistName: nil) == name)
        }
    }

    @Test("歌手字段只清理繁简容器和来源噪音")
    func cleansArtistNamesWithFieldSpecificRules() {
        let cases: [(input: String, expected: String)] = [
            ("張學友", "张学友"),
            ("动力火车合集【qobuz】", "动力火车"),
            ("SHE合集【qobuz】", "SHE"),
            ("无印良品专辑", "无印良品"),
            ("白晓专辑", "白晓"),
            ("陈佳 专辑", "陈佳"),
            ("Blink-182", "Blink-182"),
            ("逃跑计划", "逃跑计划"),
            ("传奇再现", "传奇再现")
        ]

        for testCase in cases {
            let actual = AlbumNameCleaning.cleanArtistName(testCase.input)
            #expect(actual == testCase.expected)
            #expect(AlbumNameCleaning.cleanArtistName(actual) == actual)
        }
    }
}
