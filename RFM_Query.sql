WITH
    -- Create a temp table for calculation
    Temp_tb as (
    SELECT
        CT.CustomerID,
        CAST(CT.Purchase_Date as DATE) as Purchase_date,
        CAST(CR.created_date as DATE) as Created_date,
        CT.GMV
    FROM pr01_Customer_Transaction CT
    JOIN pr01_Customer_Registered CR
    ON CT.CustomerID = CR.ID
    WHERE CustomerID <> 0 AND stopdate is NULL
),
    -- STEP 1: Create a temp RFM value from Temp Table
    Contract_age as (
        SELECT *,
               cast(Datediff(year, Created_date,'2022-09-01') as float) as Contract_age
        FROM Temp_tb
    ),

    Raw_RFM as (
    SELECT
    CustomerID,
    datediff(Day, MAX(Purchase_Date), '2022-09-01') as Recency,
    ROUND((COUNT(DISTINCT Purchase_Date) / MAX(Contract_age))*10,0) as Frequency,
--     COUNT(DISTINCT Purchase_Date) as Fre,
    ROUND(SUM(GMV) / MAX(Contract_age),0) as Monetary
    FROM Contract_age
    GROUP BY CustomerID
),
    -- STEP 2: RFM Score Calculation
    -- 2.1: Create RFM Quartile table
    R_Quartile as (
        SELECT *,
               NTILE(4) OVER (ORDER BY Recency DESC) AS R_Quartile
        FROM Raw_RFM
    ),

    --  We will calculate the F Quartile base on Frequency itself from 1-5 later
    --  The Frequency data is skew right, meant > 90% of data is '1', the rest is from 2 to 5
        --     SELECT Frequency, COUNT(Frequency) FROM R_Quartile
        --     GROUP BY Frequency;
            -- | Frequency  | Count     |
            -- | 1          | 838932    |
            -- | 2          | 96526     |
            -- | 3          | 1194      |
            -- | 4          | 6         |
            -- | 5          | 2         |

    RM_Quartile as (
        SELECT *,
               NTILE(4) OVER (ORDER BY Monetary) AS M_Quartile
        FROM R_Quartile
    ),

    -- 2.2: Create R IQR Table
    R_IQR as (
        SELECT MAX(Recency) Max,
               MAX(CASE WHEN R_Quartile = 3 THEN Recency END) AS Q3,
               MAX(CASE WHEN R_Quartile = 2 THEN Recency END) AS Median,
               MAX(CASE WHEN R_Quartile = 1 THEN Recency END) AS Q1,
               MIN(Recency) Min
        FROM RM_Quartile
    ),

    -- 2.3: Create F IQR Table
    --    Skew right data: Min = Q1 = Q2 (Median) = Q3 => modify a little bit to normal
    F_IQR as (
        SELECT MAX(Frequency) Max,
               MAX(CASE WHEN Frequency = 3 THEN Frequency END) AS Q3,
               MAX(CASE WHEN Frequency = 2 THEN Frequency END) AS Median,
               MAX(CASE WHEN Frequency = 1 THEN Frequency END) AS Q1,
               MIN(Frequency) Min
        FROM RM_Quartile
    ),

    -- 2.4: Create M IQR Table
    M_IQR as (
        SELECT MAX(Monetary) Max,
               MAX(CASE WHEN M_Quartile = 3 THEN Monetary END) AS Q3,
               MAX(CASE WHEN M_Quartile = 2 THEN Monetary END) AS Median,
               MAX(CASE WHEN M_Quartile = 1 THEN Monetary END) AS Q1,
               MIN(Monetary) Min
        FROM RM_Quartile
    ),

    -- STEP 3: Create RFM Score table attached to Customer ID
    R_F_M as (
       SELECT
        *,
        -- R Score
        (SELECT
             CASE
                WHEN Recency > R_IQR.Q3 then 1
                WHEN Recency <= R_IQR.Q3 and Recency > R_IQR.Median then 2
                WHEN Recency <= R_IQR.Median and Recency > R_IQR.Q1 then 3
                WHEN Recency <= R_IQR.Q1 then 4
                ELSE 0
            END FROM R_IQR
        ) as R_Score,
        -- F_score
        (SELECT
             CASE
                WHEN Frequency >= Q3 then 4
                WHEN Frequency < Q3 and Frequency > Median then 3
                WHEN Frequency <= Median and Frequency > Q1 then 2
                WHEN Frequency <= Q1 then 1
                ELSE 0
            END FROM F_IQR
        ) as F_Score,
        -- M_Score
        (SELECT
             CASE
                WHEN Monetary >= Q3 then 4
                WHEN Monetary < Q3 and Monetary > Median then 3
                WHEN Monetary <= Median and Monetary > Q1 then 2
                WHEN Monetary <= Q1 then 1
                ELSE 0
            END FROM M_IQR
        ) as M_Score
    FROM Raw_RFM
    ),

    RFM_Score as (
        SELECT *,
               (R_Score * 100 + F_Score * 10 + M_Score) as RFM_Sc
        FROM R_F_M
    ),

    Segmentation as (
        SELECT
            *,
            CASE
                WHEN RFM_Sc > 432 THEN 'Platinum'
                WHEN RFM_Sc <= 432 AND RFM_Sc > 411 THEN 'Gold'
                WHEN RFM_Sc <= 411 AND RFM_Sc > 211 THEN 'Silver'
                WHEN RFM_Sc <= 211 AND RFM_Sc > 111 THEN 'Bronze'
                ELSE 'Regular'
            END as Seg
        FROM RFM_Score
    )

SELECT COUNT(*) FROM Segmentation;